# frozen_string_literal: true

require "busybee/testing"

# Error class for testing exception-based BPMN errors
OrderNotFoundError = Class.new(StandardError)

RSpec.describe "throw_bpmn_error_on matcher" do
  let(:bpmn_error_worker) do
    Class.new(Busybee::Worker) do
      job_type "bpmn-error"

      def perform
        throw_bpmn_error!(:not_found, "order missing")
      end
    end
  end

  let(:exception_bpmn_worker) do
    # Capture the error class in a local for the closure
    error_class = OrderNotFoundError
    Class.new(Busybee::Worker) do
      job_type "exception-bpmn"

      define_method(:perform) do
        throw_bpmn_error!(error_class.new("order 42 missing"))
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

  let(:failing_worker) do
    Class.new(Busybee::Worker) do
      job_type "failing-worker"

      def perform
        raise StandardError, "kaboom"
      end
    end
  end

  describe "basic usage" do
    it "passes when the worker throws a BPMN error" do
      job = build_test_job
      expect(bpmn_error_worker).to throw_bpmn_error_on(job)
    end

    it "fails when the worker completes successfully" do
      job = build_test_job
      expect do
        expect(happy_worker).to throw_bpmn_error_on(job)
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError,
                         /expected job to be error, but was complete/)
    end

    it "fails when the worker raises a regular error" do
      job = build_test_job
      expect do
        expect(failing_worker).to throw_bpmn_error_on(job)
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError,
                         /to throw a BPMN error, but it raised StandardError: kaboom/)
    end
  end

  describe ".with_code chain" do
    it "passes when the error code matches" do
      job = build_test_job
      expect(bpmn_error_worker).to throw_bpmn_error_on(job).with_code("NOT_FOUND")
    end

    it "fails when the error code does not match" do
      job = build_test_job
      expect do
        expect(bpmn_error_worker).to throw_bpmn_error_on(job).with_code("TIMEOUT")
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError,
                         /expected BPMN error code "TIMEOUT".*got "NOT_FOUND"/)
    end

    it "accepts a symbol and upcases it for comparison" do
      job = build_test_job
      expect(bpmn_error_worker).to throw_bpmn_error_on(job).with_code(:not_found)
    end

    it "accepts a message: kwarg and verifies it" do
      job = build_test_job
      expect(bpmn_error_worker).to throw_bpmn_error_on(job).
        with_code(:not_found, message: "order missing")
    end

    it "fails when message does not match" do
      job = build_test_job
      expect do
        expect(bpmn_error_worker).to throw_bpmn_error_on(job).
          with_code(:not_found, message: "wrong message")
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError,
                         /expected BPMN error message "wrong message".*got "order missing"/)
    end

    it "accepts a regex for message matching" do
      job = build_test_job
      expect(bpmn_error_worker).to throw_bpmn_error_on(job).
        with_code(:not_found, message: /order/)
    end

    it "fails when regex message does not match" do
      job = build_test_job
      expect do
        expect(bpmn_error_worker).to throw_bpmn_error_on(job).
          with_code(:not_found, message: /nope/)
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError,
                         /expected BPMN error message.*nope.*got "order missing"/)
    end

    it "supports a regex for code matching" do
      job = build_test_job
      expect(bpmn_error_worker).to throw_bpmn_error_on(job).with_code(/NOT_FOUND/)
    end

    it "fails when regex code does not match" do
      job = build_test_job
      expect do
        expect(bpmn_error_worker).to throw_bpmn_error_on(job).with_code(/TIMEOUT/)
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError,
                         /expected BPMN error code.*TIMEOUT.*got "NOT_FOUND"/)
    end

    it "accepts an exception class and formats it like format_error_code" do
      job = build_test_job
      expect(exception_bpmn_worker).to throw_bpmn_error_on(job).
        with_code(OrderNotFoundError)
    end

    it "accepts an exception class with message verification" do
      job = build_test_job
      expect(exception_bpmn_worker).to throw_bpmn_error_on(job).
        with_code(OrderNotFoundError, message: /order 42/)
    end
  end
end
