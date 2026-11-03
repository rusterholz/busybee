# frozen_string_literal: true

require "concurrent"

require "busybee/testing/activated_job"
require "busybee/testing/helpers"
require "busybee/testing/no_jobs_available"

# activate_jobs against a gateway that serves each activation the next batch
# queued for it, then nothing. The instance with_process_instance starts is 1001.
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
    gateway.on(:create_process_instance) { Busybee::GRPC::CreateProcessInstanceResponse.new(processInstanceKey: 1001) }
    gateway.on(:cancel_process_instance) { Busybee::GRPC::CancelProcessInstanceResponse.new }
    gateway.on(:fail_job) { Busybee::GRPC::FailJobResponse.new }
    gateway.on(:activate_jobs) do
      [Busybee::GRPC::ActivateJobsResponse.new(jobs: batches.empty? ? [] : batches.pop)]
    end
  end

  def job(key, instance = 1001)
    FaultInjectionGateway.activated_job(key: key, type: "t", retries: 3, process_instance_key: instance)
  end

  def serve(*jobs) = batches << jobs
  def polls = gateway.received(:activate_jobs)
  def handed_back = gateway.received(:fail_job)

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

    it "returns an empty Array, raising nothing, when only foreign jobs arrive" do
      serve(job(901, 777))

      with_process_instance("p") { expect(activate_jobs("t", max_jobs: 5, timeout: 50)).to eq([]) }
    end

    [0, -1, 2.0, 2.5, "2"].each do |bad|
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

  describe "with expected:" do
    it "keeps the jobs it holds and asks only for the remainder until it has them all" do
      serve(job(1))
      serve(job(2))
      serve(job(3))

      jobs = activate_jobs("t", expected: 3)

      expect(jobs).to be_an(Array)
      expect(jobs).to all(be_a(Busybee::Testing::ActivatedJob))
      expect(jobs.map(&:key)).to eq([1, 2, 3])
      expect(polls.map(&:maxJobsToActivate)).to eq([3, 2, 1])
    end

    it "stops asking once it has them all" do
      serve(job(1), job(2))
      serve(job(3))

      expect(activate_jobs("t", expected: 2).map(&:key)).to eq([1, 2])
      expect(polls.size).to eq(1)
    end

    it "counts a job the engine offers again only once" do
      serve(job(1))
      serve(job(1))
      serve(job(2))

      expect(activate_jobs("t", expected: 2).map(&:key)).to eq([1, 2])
      expect(polls.map(&:maxJobsToActivate)).to eq([2, 1, 1])
    end

    it "stops at the end of the wait even while jobs keep arriving" do
      served = Concurrent::AtomicFixnum.new
      gateway.on(:activate_jobs) do
        raise GRPC::Internal, "still polling" if served.increment > 60

        sleep 0.02
        [Busybee::GRPC::ActivateJobsResponse.new(jobs: [job(served.value)])]
      end

      expect { activate_jobs("t", expected: 100, timeout: 200) }.to raise_error(Busybee::Testing::NoJobsAvailable)
    end

    context "when the wait runs out first" do
      it "takes an empty poll as the wait's end, not a reason to ask again" do
        serve(job(1))

        expect { activate_jobs("t", expected: 2) }.to raise_error(Busybee::Testing::NoJobsAvailable)
        expect(polls.size).to eq(2)
      end

      it "says how many it expected and how many it got, outside with_process_instance" do
        serve(job(1))

        expect { activate_jobs("t", expected: 2) }.
          to raise_error(Busybee::Testing::NoJobsAvailable, "Expected 2 jobs of type 't', got 1")
      end

      it "names the instance inside with_process_instance" do
        serve(job(1))

        with_process_instance("p") do
          expect { activate_jobs("t", expected: 2) }.
            to raise_error(Busybee::Testing::NoJobsAvailable,
                           "Expected 2 jobs of type 't' for process instance 1001, got 1")
        end
      end

      it "says job for a single job" do
        with_process_instance("p") do
          expect { activate_jobs("t", expected: 1) }.
            to raise_error(Busybee::Testing::NoJobsAvailable,
                           "Expected 1 job of type 't' for process instance 1001, got 0")
        end
      end

      it "names what it handed back, and the switch" do
        serve(job(1), job(901, 777))

        with_process_instance("p") do
          expect { activate_jobs("t", expected: 2) }.to raise_error(
            Busybee::Testing::NoJobsAvailable,
            "Expected 2 jobs of type 't' for process instance 1001, got 1. Handed back unworked: " \
            "1 job of another process instance (777). To accept jobs of instances the example " \
            "didn't start itself, such as a call activity's, tag it busybee_foreign_jobs: :accept"
          )
        end
      end

      it "keeps holding the jobs it activated" do
        serve(job(1))

        with_process_instance("p") { expect { activate_jobs("t", expected: 2) }.to raise_error(Busybee::Testing::NoJobsAvailable) }

        expect(handed_back).to be_empty
      end
    end

    context "with foreign jobs mixed in, inside with_process_instance" do
      it "hands them back, doesn't count them, and keeps asking for its own" do
        serve(job(901, 777), job(1))
        serve(job(902, 778))
        serve(job(2))

        with_process_instance("p") { expect(activate_jobs("t", expected: 2).map(&:key)).to eq([1, 2]) }

        expect(polls.map(&:maxJobsToActivate)).to eq([2, 1, 1])
        expect(handed_back.map { |r| [r.jobKey, r.retries, r.retryBackOff] }).to eq([[901, 3, 250], [902, 3, 500]])
      end

      it "takes them under busybee_foreign_jobs: :accept", busybee_foreign_jobs: :accept do
        serve(job(901, 777), job(1))

        with_process_instance("p") { expect(activate_jobs("t", expected: 2).map(&:key)).to eq([901, 1]) }

        expect(handed_back).to be_empty
      end
    end

    it "takes any instance's jobs outside with_process_instance" do
      serve(job(901, 777), job(902, 778))

      expect(activate_jobs("t", expected: 2).map(&:key)).to eq([901, 902])
      expect(handed_back).to be_empty
    end

    [0, -1, 2.0, 2.5, "2"].each do |bad|
      it "refuses expected: #{bad.inspect} without asking the engine" do
        expect { activate_jobs("t", expected: bad) }.
          to raise_error(ArgumentError, /\Aexpected: must be a positive Integer, got #{Regexp.escape(bad.inspect)}/)
        expect(polls).to be_empty
      end
    end

    it "points expected: 0 to the check for no jobs" do
      expect { activate_jobs("t", expected: 0) }.to raise_error(
        ArgumentError,
        "expected: must be a positive Integer, got 0. To check that no job is waiting, " \
        "use expect { activate_job(type) }.not_to have_available_jobs"
      )
    end
  end

  it "refuses expected: and max_jobs: together" do
    expect { activate_jobs("t", expected: 2, max_jobs: 2) }.
      to raise_error(ArgumentError, "Pass exactly one of expected: or max_jobs:")
    expect(polls).to be_empty
  end

  it "refuses neither expected: nor max_jobs:" do
    expect { activate_jobs("t") }.to raise_error(ArgumentError, "Pass exactly one of expected: or max_jobs:")
    expect(polls).to be_empty
  end
end
