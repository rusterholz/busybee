# frozen_string_literal: true

require "busybee/testing/helpers"
require "busybee/testing/matchers/have_available_jobs"

RSpec.describe "have_available_jobs", :gateway do
  let(:batches) { Queue.new }
  let(:expectation_failure) { RSpec::Expectations::ExpectationNotMetError }

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

  def job(key) = FaultInjectionGateway.activated_job(key: key, type: "t")
  def serve(*jobs) = batches << jobs

  context "when the block activates a job" do
    before { serve(job(1)) }

    it("matches") { expect { activate_job("t") }.to have_available_jobs }

    it "fails the negated form" do
      expect { expect { activate_job("t") }.not_to have_available_jobs }.
        to raise_error(expectation_failure, "expected no jobs to be available, but a job was activated")
    end
  end

  context "when the block raises NoJobsAvailable" do
    it("doesn't match") { expect { activate_job("t", timeout: 50) }.not_to have_available_jobs }

    it "says what the block raised" do
      expect { expect { activate_job("t", timeout: 50) }.to have_available_jobs }.to raise_error(
        expectation_failure,
        "expected jobs to be available, but got Busybee::Testing::NoJobsAvailable: No job of type 't' available"
      )
    end
  end

  context "when too few of the expected jobs arrive" do
    before { serve(job(1)) }

    it("doesn't match") { expect { activate_jobs("t", expected: 2) }.not_to have_available_jobs }

    it "says how many arrived" do
      expect { expect { activate_jobs("t", expected: 2) }.to have_available_jobs }.to raise_error(
        expectation_failure,
        "expected jobs to be available, but got Busybee::Testing::NoJobsAvailable: " \
        "Expected 2 jobs of type 't', got 1"
      )
    end
  end

  context "when the block returns an empty Array" do
    it("doesn't match") { expect { activate_jobs("t", max_jobs: 3, timeout: 50) }.not_to have_available_jobs }

    it "fails the positive form" do
      expect { expect { activate_jobs("t", max_jobs: 3, timeout: 50) }.to have_available_jobs }.
        to raise_error(expectation_failure, "expected jobs to be available, but none were activated")
    end
  end

  context "when the block returns jobs in an Array" do
    before { serve(job(1), job(2)) }

    it("matches") { expect { activate_jobs("t", max_jobs: 3) }.to have_available_jobs }

    it "fails the negated form" do
      expect { expect { activate_jobs("t", max_jobs: 3) }.not_to have_available_jobs }.
        to raise_error(expectation_failure, "expected no jobs to be available, but a job was activated")
    end
  end

  context "when the block raises anything else" do
    before { gateway.on(:activate_jobs) { raise GRPC::Unavailable, "gateway restarting" } }

    it "surfaces the error from the positive form" do
      expect { expect { activate_job("t") }.to have_available_jobs }.
        to raise_error(GRPC::Unavailable, /gateway restarting/)
    end

    it "surfaces the error from the negated form" do
      expect { expect { activate_job("t") }.not_to have_available_jobs }.
        to raise_error(GRPC::Unavailable, /gateway restarting/)
    end

    it "surfaces a bad argument from the negated form" do
      expect { expect { activate_jobs("t", expected: 0) }.not_to have_available_jobs }.
        to raise_error(ArgumentError, /expected: must be a positive Integer/)
    end
  end

  context "when an expectation inside the block fails" do
    before { serve(job(1)) }

    it "surfaces that failure from the positive form" do
      expect { expect { activate_job("t").expect_variables(nope: 1) }.to have_available_jobs }.
        to raise_error(expectation_failure, /nope/)
    end

    it "surfaces that failure from the negated form" do
      expect { expect { activate_job("t").expect_variables(nope: 1) }.not_to have_available_jobs }.
        to raise_error(expectation_failure, /nope/)
    end
  end

  context "when the block raises another testing error" do
    it "surfaces it from the positive form" do
      expect { expect { assert_process_completed!(wait: 0) }.to have_available_jobs }.
        to raise_error(Busybee::Testing::NoCurrentProcessInstance)
    end

    it "surfaces it from the negated form" do
      expect { expect { assert_process_completed!(wait: 0) }.not_to have_available_jobs }.
        to raise_error(Busybee::Testing::NoCurrentProcessInstance)
    end

    it "surfaces a process still running" do
      gateway.on(:create_process_instance) { Busybee::GRPC::CreateProcessInstanceResponse.new(processInstanceKey: 1001) }
      gateway.on(:cancel_process_instance) { Busybee::GRPC::CancelProcessInstanceResponse.new }

      with_process_instance("p") do
        expect { expect { assert_process_completed!(wait: 0) }.not_to have_available_jobs }.
          to raise_error(Busybee::Testing::ProcessStillRunning)
      end
    end
  end
end
