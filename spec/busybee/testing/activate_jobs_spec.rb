# frozen_string_literal: true

require "busybee/testing/activated_job"
require "busybee/testing/helpers"

# activate_jobs against a gateway that serves each activation the next batch
# queued for it, then nothing.
RSpec.describe "activate_jobs", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:batches) { Queue.new }

  around do |example|
    saved = [Busybee.credential_type, Busybee.cluster_address]
    Busybee.credential_type = :insecure
    example.run
  ensure
    Busybee.credential_type, Busybee.cluster_address = saved
  end

  before do
    Busybee.cluster_address = gateway.address
    gateway.on(:activate_jobs) do
      [Busybee::GRPC::ActivateJobsResponse.new(jobs: batches.empty? ? [] : batches.pop)]
    end
  end

  def job(key) = FaultInjectionGateway.activated_job(key: key, type: "t", process_instance_key: 777)
  def serve(*jobs) = batches << jobs
  def polls = gateway.received(:activate_jobs)

  describe "with max_jobs:" do
    it "returns an Array of the jobs it activated" do
      serve(job(1), job(2))

      jobs = activate_jobs("t", max_jobs: 5)

      expect(jobs).to be_an(Array)
      expect(jobs).to all(be_a(Busybee::Testing::ActivatedJob))
      expect(jobs.map(&:key)).to eq([1, 2])
    end

    it "activates when called, whether or not the result is read" do
      serve(job(1))

      activate_jobs("t", max_jobs: 5)

      expect(polls.size).to eq(1)
    end

    it "activates once, however often the result is read" do
      serve(job(1), job(2))

      jobs = activate_jobs("t", max_jobs: 5)

      expect([jobs.size, jobs.first.key, jobs.to_a.size, jobs.map(&:key)]).to eq([2, 1, 2, [1, 2]])
      expect(polls.size).to eq(1)
    end

    it "asks for max_jobs and settles for fewer" do
      serve(job(1))
      serve(job(2))

      expect(activate_jobs("t", max_jobs: 5).map(&:key)).to eq([1])
      expect(polls.map(&:maxJobsToActivate)).to eq([5])
    end

    it "returns an empty Array when nothing arrives" do
      expect(activate_jobs("t", max_jobs: 5, timeout: 50)).to eq([])
    end

    [0, -1, 2.0, 2.5, "2", nil].each do |bad|
      it "refuses max_jobs: #{bad.inspect} without asking the engine" do
        expect { activate_jobs("t", max_jobs: bad) }.
          to raise_error(ArgumentError, /\Amax_jobs: must be a positive Integer, got #{Regexp.escape(bad.inspect)}/)
        expect(polls).to be_empty
      end
    end

    it "points max_jobs: 0 to the check for no jobs" do
      expect { activate_jobs("t", max_jobs: 0) }.to raise_error(
        ArgumentError,
        "max_jobs: must be a positive Integer, got 0. To check that no job is waiting, " \
        "use expect { activate_job(type) }.not_to have_available_jobs"
      )
    end
  end
end
