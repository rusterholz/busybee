# frozen_string_literal: true

RSpec.describe FaultInjectionGateway do
  it "binds a loopback port and reports the address it actually bound" do
    gateway = described_class.new
    gateway.start

    expect(gateway.address).to match(/\A127\.0\.0\.1:\d+\z/)
    expect(gateway.address).not_to end_with(":0")
  ensure
    gateway&.stop
  end

  it "raises an actionable error rather than binding silently to nothing" do
    gateway = described_class.new(bind: "not-a-real-host.invalid:0")

    silencing_stderr do
      expect { gateway.start }.to raise_error(/could not bind.*not-a-real-host\.invalid:0.*bind:/im)
    end
  ensure
    gateway&.stop
  end

  describe "programming a response", :gateway do
    it "returns what the spec programmed, through a client built the real way" do
      gateway.on(:publish_message) { Busybee::GRPC::PublishMessageResponse.new(key: 12_345) }

      key = gateway.client.publish_message("order-shipped", correlation_key: "A1")

      expect(key).to eq(12_345)
    end
  end

  describe "recording requests", :gateway do
    it "records what actually reached the wire, in order" do
      gateway.on(:publish_message) { Busybee::GRPC::PublishMessageResponse.new(key: 1) }

      gateway.client.publish_message("order-shipped", correlation_key: "A1")
      gateway.client.publish_message("order-cancelled", correlation_key: "B2")

      expect(gateway.received(:publish_message).map(&:name)).to eq(%w[order-shipped order-cancelled])
      expect(gateway.received(:publish_message).map(&:correlationKey)).to eq(%w[A1 B2])
    end

    it "records requests for RPCs that were never programmed" do
      expect { gateway.client.publish_message("unhandled", correlation_key: "C3") }.
        to raise_error(Busybee::GRPC::Error)

      expect(gateway.received(:publish_message).map(&:name)).to eq(["unhandled"])
    end
  end

  describe "server-streaming RPCs", :gateway do
    it "yields real jobs decoded from a genuine streaming response" do
      job = described_class.activated_job(type: "send-email", variables: { to: "a@b.c" })
      response = Busybee::GRPC::ActivateJobsResponse.new(jobs: [job])
      gateway.on(:activate_jobs) { [response] }

      seen = []
      count = gateway.client.with_each_job("send-email") { |activated| seen << activated }

      expect(count).to eq(1)
      expect(seen.map(&:type)).to eq(["send-email"])
      expect(seen.first.variables[:to]).to eq("a@b.c")
    end

    it "streams lazily, so good responses arrive before a mid-stream failure" do
      response = Busybee::GRPC::ActivateJobsResponse.new(
        jobs: [described_class.activated_job(type: "send-email")]
      )
      gateway.on(:activate_jobs) do
        Enumerator.new do |yielder|
          yielder << response
          raise GRPC::Unavailable, "broker went away mid-stream"
        end
      end

      seen = []
      expect { gateway.client.with_each_job("send-email") { |job| seen << job } }.
        to raise_error(GRPC::BadStatus)

      expect(seen.size).to eq(1)
    end

    # A status error on a server-streaming RPC arrives raw, while the same status
    # on a unary RPC arrives wrapped as Busybee::GRPC::Error. The asymmetry is
    # real, and it decides whether the fetch loops' rescue clauses match at all.
    it "surfaces a streaming status error during enumeration, unwrapped" do
      gateway.on(:activate_jobs) { raise GRPC::ResourceExhausted, "broker under pressure" }

      raised = nil
      begin
        gateway.client.with_each_job("send-email") { |_job| nil }
      rescue StandardError => e
        raised = e
      end

      expect(raised).to be_a(GRPC::BadStatus)
      expect(raised.code).to eq(GRPC::Core::StatusCodes::RESOURCE_EXHAUSTED)
      expect(raised).not_to be_a(Busybee::GRPC::Error)
    end

    it "delivers jobs through the long-lived stream RPC" do
      gateway.on(:stream_activated_jobs) { [described_class.activated_job(type: "send-email")] }

      # JobStream is Enumerable, so map still drives the #each under test.
      types = gateway.client.open_job_stream("send-email").map(&:type)

      expect(types).to eq(["send-email"])
    end

    # The long-lived stream wraps where the polling fetch does not, and the wrap
    # keeps grpc_status readable through Ruby's implicit cause — which is exactly
    # what the runner's backpressure match reads.
    it "wraps a stream status error while preserving grpc_status" do
      gateway.on(:stream_activated_jobs) { raise GRPC::ResourceExhausted, "broker under pressure" }

      raised = nil
      begin
        gateway.client.open_job_stream("send-email").each { |_job| nil }
      rescue StandardError => e
        raised = e
      end

      expect(raised).to be_a(Busybee::GRPC::Error)
      expect(raised.grpc_status).to eq(:resource_exhausted)
    end
  end

  describe "the :gateway RSpec integration" do
    it "hands the example a started gateway", :gateway do
      expect(gateway).to be_a(described_class)
      expect(gateway.address).to match(/\A127\.0\.0\.1:\d+\z/)
    end

    it "is reachable by a real client without any further setup", :gateway do
      gateway.on(:publish_message) { Busybee::GRPC::PublishMessageResponse.new(key: 7) }

      expect(gateway.client.publish_message("m", correlation_key: "k")).to eq(7)
    end
  end

  # grpc's C core logs a bind failure straight to fd 2, so a deliberately-failing
  # bind litters the suite with an E0000 line that looks like a real defect.
  # Reopening $stderr moves the underlying fd, so the C writes follow it.
  def silencing_stderr
    original = $stderr.dup
    $stderr.reopen(File::NULL)
    yield
  ensure
    $stderr.reopen(original)
    original.close
  end
end
