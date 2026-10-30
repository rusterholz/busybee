# frozen_string_literal: true

require "concurrent"

require "busybee/testing/helpers"

# with_process_instance and with_activated_job_instance against a gateway that
# answers like Zeebe: instance keys count up from 1001, cancels succeed.
RSpec.describe "with_process_instance blocks", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:instance_keys) { Concurrent::AtomicFixnum.new(1000) }

  def canceled = gateway.received(:cancel_process_instance).map(&:processInstanceKey)
  def completed = gateway.received(:complete_job).map(&:jobKey)

  around do |example|
    saved = [Busybee.credential_type, Busybee.cluster_address]
    Busybee.credential_type = :insecure
    example.run
  ensure
    Busybee.credential_type, Busybee.cluster_address = saved
  end

  before do
    Busybee.cluster_address = gateway.address
    gateway.on(:create_process_instance) do
      Busybee::GRPC::CreateProcessInstanceResponse.new(processInstanceKey: instance_keys.increment)
    end
    gateway.on(:cancel_process_instance) { Busybee::GRPC::CancelProcessInstanceResponse.new }
    gateway.on(:complete_job) { Busybee::GRPC::CompleteJobResponse.new }
  end

  def serve_jobs(*jobs)
    queue = Queue.new
    jobs.each { |job| queue << job }
    gateway.on(:activate_jobs) do
      job = queue.empty? ? nil : queue.pop
      [Busybee::GRPC::ActivateJobsResponse.new(jobs: [job].compact)]
    end
  end

  describe "nested" do
    it "cancels each instance as its own block ends" do
      with_process_instance("p") do
        with_process_instance("p") { |_| } # rubocop:disable Lint/EmptyBlock
        expect(canceled).to eq([1002])
      end

      expect(canceled).to eq([1002, 1001])
    end

    it "hands the outer instance back to the helpers once the inner block ends" do
      with_process_instance("p") do |outer|
        with_process_instance("p") { |inner| expect(process_instance_key).to eq(inner) }
        expect(process_instance_key).to eq(outer)

        gateway.on(:cancel_process_instance) { raise GRPC::NotFound, "already completed" }
        assert_process_completed!(wait: 0)
      end

      expect(canceled).to eq([1002, 1001, 1001])
      expect(last_process_instance_key).to eq(1001)
    end

    it "leaves the outer instance alone when the inner one fails to start" do
      with_process_instance("p") do
        gateway.on(:create_process_instance) { raise GRPC::NotFound, "no process 'missing'" }
        expect { with_process_instance("missing") { |_| } }.to raise_error(GRPC::NotFound) # rubocop:disable Lint/EmptyBlock
        expect(canceled).to be_empty
        expect(process_instance_key).to eq(1001)
      end

      expect(canceled).to eq([1001])
    end

    it "leaves no instance current once the blocks raise" do
      expect do
        with_process_instance("p") { with_process_instance("p") { raise "spec failed" } }
      end.to raise_error("spec failed")

      expect(process_instance_key).to be_nil
      expect(canceled).to eq([1002, 1001])
    end
  end

  describe "a cancel that fails" do
    before { gateway.on(:cancel_process_instance) { raise GRPC::ResourceExhausted, "broker under pressure" } }

    it "leaves the example's own failure as the one reported, and warns of the instance left running" do
      expect do
        expect do
          with_process_instance("p") { raise RSpec::Expectations::ExpectationNotMetError, "the example's own" }
        end.to raise_error(RSpec::Expectations::ExpectationNotMetError, "the example's own")
      end.to output(
        /\A\[busybee\] Failed to cancel process instance 1001 after the example failed; it is still running \(GRPC::ResourceExhausted: 8:broker under pressure/ # rubocop:disable Layout/LineLength
      ).to_stderr
    end

    it "fails an example that otherwise passed" do
      expect { with_process_instance("p") { |_| } }.to raise_error(GRPC::ResourceExhausted) # rubocop:disable Lint/EmptyBlock
    end
  end

  describe "nested with_activated_job_instance" do
    it "leaves the outer job alone when the inner activation finds nothing" do
      serve_jobs(FaultInjectionGateway.activated_job(key: 501, type: "t", process_instance_key: 1001))

      with_process_instance("p") do
        with_activated_job_instance("t") do |job|
          expect { with_activated_job_instance("t") { |_| } }.to raise_error(Busybee::Testing::NoJobAvailable) # rubocop:disable Lint/EmptyBlock
          expect(completed).to be_empty
          expect(job.key).to eq(501)
        end
        expect(completed).to eq([501])
      end
    end
  end
end
