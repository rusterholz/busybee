# frozen_string_literal: true

require "busybee/testing"

RSpec.describe "fail_job matcher" do
  let(:failing_worker) do
    Class.new(Busybee::Worker) do
      job_type "failing-worker"

      def perform
        raise StandardError, "kaboom"
      end
    end
  end

  let(:argument_error_worker) do
    Class.new(Busybee::Worker) do
      job_type "argument-error-worker"

      def perform
        raise ArgumentError, "bad input"
      end
    end
  end

  let(:happy_worker) do
    Class.new(Busybee::Worker) do
      job_type "happy-worker"
      strict_outputs false

      def perform
        { status: "done" }
      end
    end
  end

  # Raises, but the job is already settled by the time it does — so the worker
  # did fail, and the job did not.
  let(:completing_then_raising_worker) do
    Class.new(Busybee::Worker) do
      job_type "resolved-before-raising"
      strict_outputs false

      def perform
        complete!(done: true)
        raise StandardError, "kaboom"
      end
    end
  end

  describe "basic usage" do
    it "passes when the worker fails the job" do
      job = build_test_job
      expect(failing_worker).to fail_job(job)
    end

    it "fails when the worker completes successfully" do
      job = build_test_job
      expect do
        expect(happy_worker).to fail_job(job)
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError,
                         /to fail the job, but it completed successfully/)
    end
  end

  describe ".with_error chain" do
    it "passes when error class matches" do
      job = build_test_job
      expect(failing_worker).to fail_job(job).with_error(StandardError)
    end

    it "passes with a subclass match (=== semantics)" do
      job = build_test_job
      expect(argument_error_worker).to fail_job(job).with_error(StandardError)
    end

    it "fails when error class does not match" do
      job = build_test_job
      expect do
        expect(failing_worker).to fail_job(job).with_error(ArgumentError)
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError,
                         /expected error matching ArgumentError/)
    end

    it "supports message matching with a Regexp" do
      job = build_test_job
      expect(failing_worker).to fail_job(job).with_error(/kaboom/)
    end

    it "fails when message regexp does not match" do
      job = build_test_job
      expect do
        expect(failing_worker).to fail_job(job).with_error(/nope/)
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError,
                         /expected error matching.*nope/)
    end

    it "supports error class with message pattern (two-arg form)" do
      job = build_test_job
      expect(failing_worker).to fail_job(job).with_error(StandardError, /kaboom/)
    end

    it "fails when class matches but message does not (two-arg form)" do
      job = build_test_job
      expect do
        expect(failing_worker).to fail_job(job).with_error(StandardError, /nope/)
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError,
                         /expected error matching/)
    end

    it "supports error class with exact message string" do
      job = build_test_job
      expect(failing_worker).to fail_job(job).with_error(StandardError, "kaboom")
    end

    it "fails when exact message string does not match" do
      job = build_test_job
      expect do
        expect(failing_worker).to fail_job(job).with_error(StandardError, "wrong")
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError,
                         /expected error matching/)
    end

    it "supports a bare string as message matcher" do
      job = build_test_job
      expect(failing_worker).to fail_job(job).with_error("kaboom")
    end
  end

  describe "when the worker raised but the job reached another outcome" do
    it "fails because the job is not marked as failed" do
      job = build_test_job
      expect do
        expect(completing_then_raising_worker).to fail_job(job)
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError,
                         /expected job to be failed, but was complete/)
    end
  end

  describe "failure messages" do
    it "includes the worker class name when no error raised" do
      job = build_test_job
      expect do
        expect(happy_worker).to fail_job(job)
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError,
                         /to fail the job/)
    end

    it "includes actual error details when error class mismatches" do
      job = build_test_job
      expect do
        expect(failing_worker).to fail_job(job).with_error(ArgumentError)
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError,
                         /got StandardError: kaboom/)
    end
  end
end
