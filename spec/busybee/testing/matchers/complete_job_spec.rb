# frozen_string_literal: true

require "busybee/testing"

RSpec.describe "complete_job matcher" do
  let(:happy_worker) do
    Class.new(Busybee::Worker) do
      job_type "happy-worker"

      def perform
        { status: "done", count: 42 }
      end
    end
  end

  let(:failing_worker) do
    Class.new(Busybee::Worker) do
      job_type "failing-worker"

      def perform
        raise StandardError, "kaboom"
      end
    end
  end

  let(:no_autocomplete_worker) do
    Class.new(Busybee::Worker) do
      job_type "no-autocomplete"
      complete_job_on_success false

      def perform
        { status: "pending" }
      end
    end
  end

  let(:manual_complete_worker) do
    Class.new(Busybee::Worker) do
      job_type "manual-complete"
      complete_job_on_success false

      def perform
        complete!(tracking: "ABC123")
        { status: "shipped" }
      end
    end
  end

  let(:nil_return_worker) do
    Class.new(Busybee::Worker) do
      job_type "nil-return"

      def perform
        # side effect only, no return value
      end
    end
  end

  describe "basic usage" do
    it "passes when the worker completes the job" do
      job = build_test_job
      expect(happy_worker).to complete_job(job)
    end

    it "fails when the worker raises an error" do
      job = build_test_job
      expect do
        expect(failing_worker).to complete_job(job)
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError,
                         /to complete the job, but it raised StandardError: kaboom/)
    end

    it "fails when the job is not marked complete" do
      job = build_test_job
      expect do
        expect(no_autocomplete_worker).to complete_job(job)
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError,
                         /expected job to be complete, but was ready/)
    end

    it "passes when worker manually completes the job" do
      job = build_test_job
      expect(manual_complete_worker).to complete_job(job)
    end
  end

  describe ".with_vars chain" do
    it "passes when return value exactly matches" do
      job = build_test_job
      expect(happy_worker).to complete_job(job).with_vars(status: "done", count: 42)
    end

    it "fails on subset match (use hash_including for subset)" do
      job = build_test_job
      expect do
        expect(happy_worker).to complete_job(job).with_vars(status: "done")
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError,
                         /expected result to match/)
    end

    it "supports hash_including for subset matching" do
      job = build_test_job
      expect(happy_worker).to complete_job(job).
        with_vars(hash_including(status: "done"))
    end

    it "supports composable matchers in values" do
      job = build_test_job
      expect(happy_worker).to complete_job(job).
        with_vars(hash_including(count: a_value > 40))
    end

    it "fails when return value does not match" do
      job = build_test_job
      expect do
        expect(happy_worker).to complete_job(job).with_vars(missing: "value")
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError,
                         /expected result to match/)
    end
  end

  describe "when perform returns a non-hash" do
    it "passes with with_no_vars" do
      job = build_test_job
      expect(nil_return_worker).to complete_job(job).with_no_vars
    end

    it "passes with with_vars({})" do
      job = build_test_job
      expect(nil_return_worker).to complete_job(job).with_vars({})
    end

    it "fails with with_vars expecting variables" do
      job = build_test_job
      expect do
        expect(nil_return_worker).to complete_job(job).with_vars(status: "done")
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError,
                         /expected result to match/)
    end
  end

  describe ".with_no_vars chain" do
    it "passes when perform returns no variables" do
      job = build_test_job
      expect(nil_return_worker).to complete_job(job).with_no_vars
    end

    it "fails when perform returns variables" do
      job = build_test_job
      expect do
        expect(happy_worker).to complete_job(job).with_no_vars
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError,
                         /expected result to match/)
    end
  end
end
