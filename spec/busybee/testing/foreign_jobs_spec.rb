# frozen_string_literal: true

require "concurrent"

require "busybee/testing/foreign_jobs"
require "busybee/testing/helpers"
require "busybee/testing/no_job_available"
require "busybee/testing/timings"

# Activation inside with_process_instance, against a gateway that serves each
# activation the next batch queued for it, then nothing. Instance keys count up
# from 1001.
RSpec.describe "Foreign jobs in workflow tests", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:instance_keys) { Concurrent::AtomicFixnum.new(1000) }
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
    gateway.on(:create_process_instance) do
      Busybee::GRPC::CreateProcessInstanceResponse.new(processInstanceKey: instance_keys.increment)
    end
    gateway.on(:cancel_process_instance) { Busybee::GRPC::CancelProcessInstanceResponse.new }
    gateway.on(:fail_job) { Busybee::GRPC::FailJobResponse.new }
    gateway.on(:activate_jobs) do
      [Busybee::GRPC::ActivateJobsResponse.new(jobs: batches.empty? ? [] : batches.pop)]
    end
  end

  def job(key, instance, retries: 3)
    FaultInjectionGateway.activated_job(key: key, type: "t", retries: retries,
                                        process_instance_key: instance)
  end

  def serve(*jobs) = batches << jobs
  def handed_back = gateway.received(:fail_job)

  describe "inside with_process_instance" do
    it "hands back another instance's job unworked and returns its own" do
      serve(job(901, 777, retries: 2))
      serve(job(501, 1001))

      with_process_instance("p") { expect(activate_job("t").key).to eq(501) }

      expect(handed_back.map { |r| [r.jobKey, r.retries, r.retryBackOff] }).
        to eq([[901, 2, Busybee::Testing::FOREIGN_JOB_BACKOFF_MS]])
      expect(handed_back.first.errorMessage).
        to eq("Handed back unworked by a busybee workflow test: " \
              "the job belongs to process instance 777, not the test's process instance 1001")
    end

    it "names what it handed back, and the switch, when nothing of its own arrives" do
      serve(job(901, 777), job(902, 778))

      with_process_instance("p") do
        expect { activate_job("t") }.to raise_error(
          Busybee::Testing::NoJobAvailable,
          "No job of type 't' available for process instance 1001. Handed back unworked: " \
          "2 jobs of other process instances (777, 778). To accept jobs of instances the example " \
          "didn't start itself, such as a call activity's, tag it busybee_foreign_jobs: :accept"
        )
      end
    end

    it "hands back the batch's foreign jobs and returns the rest from activate_jobs" do
      serve(job(501, 1001), job(901, 777), job(502, 1001))

      with_process_instance("p") { expect(activate_jobs("t", max_jobs: 3).map(&:key)).to eq([501, 502]) }

      expect(handed_back.map(&:jobKey)).to eq([901])
    end

    it "says an enclosing block's job waits for that block, without suggesting the tag" do
      serve(job(501, 1001))

      with_process_instance("p") do
        with_process_instance("p") do
          expect { activate_job("t") }.to raise_error(
            Busybee::Testing::NoJobAvailable,
            "No job of type 't' available for process instance 1002. Handed back unworked: " \
            "1 job of an enclosing with_process_instance block's process instance (1001), " \
            "which can take it once that block resumes"
          )
        end
      end
    end

    it "words an enclosing block's job and another instance's each on its own" do
      serve(job(501, 1001), job(901, 777))

      with_process_instance("p") do
        with_process_instance("p") do
          expect { activate_job("t") }.to raise_error(
            Busybee::Testing::NoJobAvailable,
            "No job of type 't' available for process instance 1002. Handed back unworked: " \
            "1 job of an enclosing with_process_instance block's process instance (1001), " \
            "which can take it once that block resumes, and 1 job of another process instance (777). " \
            "To accept jobs of instances the example didn't start itself, such as a call activity's, " \
            "tag it busybee_foreign_jobs: :accept"
          )
        end
      end
    end

    it "refuses the enclosing block's job inside an inner block" do
      serve(job(501, 1001))
      serve(job(502, 1002))

      with_process_instance("p") do
        with_process_instance("p") { expect(activate_job("t").key).to eq(502) }
      end

      expect(handed_back.map(&:jobKey)).to eq([501])
    end
  end

  it "accepts any job outside with_process_instance" do
    serve(job(901, 777))

    expect(activate_job("t").key).to eq(901)
    expect(handed_back).to be_empty
  end

  describe "accepting foreign jobs" do
    it "accepts jobs of instances the example didn't start", busybee_foreign_jobs: :accept do
      serve(job(901, 777))

      with_process_instance("p") { expect(activate_job("t").key).to eq(901) }

      expect(handed_back).to be_empty
    end

    it "still refuses the enclosing block's job, and says why", busybee_foreign_jobs: :accept do
      serve(job(501, 1001))

      with_process_instance("p") do
        with_process_instance("p") do
          expect { activate_job("t") }.to raise_error(
            Busybee::Testing::NoJobAvailable,
            "No job of type 't' available for process instance 1002. Handed back unworked: " \
            "1 job of an enclosing with_process_instance block's process instance (1001), " \
            "which can take it once that block resumes"
          )
        end
      end
    end

    context "with the metadata on the group", busybee_foreign_jobs: :accept do
      it "lets an example go back to refusing", busybee_foreign_jobs: :refuse do
        serve(job(901, 777))

        with_process_instance("p") { expect { activate_job("t") }.to raise_error(Busybee::Testing::NoJobAvailable) }
      end
    end

    it "accepts inside the block form, and refuses again once it ends, even by raising" do
      serve(job(901, 777))
      serve(job(902, 778))

      with_process_instance("p") do
        Busybee::Testing.accepting_foreign_jobs { expect(activate_job("t").key).to eq(901) }
        expect { Busybee::Testing.accepting_foreign_jobs { raise "spec failed" } }.to raise_error("spec failed")
        expect { activate_job("t") }.to raise_error(Busybee::Testing::NoJobAvailable)
      end
    end

    it "refuses a mode it doesn't know" do
      expect { Busybee::Testing.with_foreign_jobs(:allow) { nil } }.
        to raise_error(ArgumentError, "Unknown busybee_foreign_jobs mode :allow. Expected :refuse or :accept")
    end
  end
end
