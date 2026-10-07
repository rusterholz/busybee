# frozen_string_literal: true

# A retried call, over a real wire, as the three call hooks see it: once per
# logical call at the edges, once per attempt in the middle.
RSpec.describe "a retried call seen by its call hooks", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:client) { gateway.client }
  let(:events) { [] }

  around { |example| isolate_busybee_hooks { example.run } }

  before do
    Busybee.grpc_retry_enabled = true
    Busybee.grpc_retry_delay = 0
    Busybee.before_call { |call| events << [:before, call.attempts] }
    Busybee.around_call do |call, continue|
      events << [:around, call.attempts]
      continue.call
    end
    Busybee.after_call { |call| events << [:after, call.attempts, call.status, call.grpc_status] }
  end

  after do
    Busybee.grpc_retry_enabled = nil
    Busybee.grpc_retry_delay = nil
  end

  def raised_by
    yield
    nil
  rescue Busybee::GRPC::Error => e
    e
  end

  context "when the first attempt meets a retryable status and the second lands" do
    before do
      sends = 0
      gateway.on(:complete_job) do
        sends += 1
        raise GRPC::Unavailable, "broker blinked" if sends == 1

        Busybee::GRPC::CompleteJobResponse.new
      end
    end

    it "fires before_call and after_call once, around_call per attempt" do
      client.complete_job(5)

      expect(events).to eq([[:before, 0], [:around, 1], [:around, 2], [:after, 2, :succeeded, :ok]])
    end

    it "shows the second attempt the first one's status while the call is still pending" do
      seen = []
      Busybee.around_call do |call, continue|
        seen << [call.status, call.grpc_status]
        continue.call
      end

      client.complete_job(5)

      expect(seen).to eq([[:pending, nil], %i[pending unavailable]])
    end

    it "times both attempts and the gap between them" do
      seen = nil
      Busybee.after_call { |call| seen = call }

      client.complete_job(5)

      expect(seen.cumulative_network_ms).to be >= seen.network_ms
      expect(seen.backoff_ms).to be_a(Float)
    end
  end

  context "when every attempt meets a retryable status" do
    before { gateway.on(:complete_job) { raise GRPC::Unavailable, "broker gone" } }

    it "resolves errored once, after the last attempt, with the status the caller also gets" do
      raised = raised_by { client.complete_job(5) }

      expect(events).to eq([[:before, 0], [:around, 1], [:around, 2], [:after, 2, :errored, :unavailable]])
      expect(raised.grpc_status).to eq(:unavailable)
      expect(gateway.received(:complete_job).size).to eq(2)
    end
  end

  context "when the status is not retryable" do
    before { gateway.on(:complete_job) { raise GRPC::InvalidArgument, "no such variable shape" } }

    it "makes one attempt and resolves errored on it" do
      raised = raised_by { client.complete_job(5) }

      expect(events).to eq([[:before, 0], [:around, 1], [:after, 1, :errored, :invalid_argument]])
      expect(raised.grpc_status).to eq(:invalid_argument)
    end
  end
end
