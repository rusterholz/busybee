# frozen_string_literal: true

require "busybee/testing"

RSpec.describe Busybee::Testing::Helpers::Execution do
  # Minimal worker for testing the helpers
  let(:worker_class) do
    Class.new(Busybee::Worker) do
      job_type "test-worker"

      def perform
        { status: "done" }
      end
    end
  end

  describe "#build_test_job" do
    it "returns a Busybee::Job" do
      job = build_test_job
      expect(job).to be_a(Busybee::Job)
    end

    it "starts with :ready status" do
      job = build_test_job
      expect(job).to be_ready
    end

    it "parses variables into the job" do
      job = build_test_job(variables: { order_id: 42, name: "test" })
      expect(job.variables[:order_id]).to eq(42)
      expect(job.variables[:name]).to eq("test")
    end

    it "parses headers into the job" do
      job = build_test_job(headers: { algorithm: "haversine" })
      expect(job.headers[:algorithm]).to eq("haversine")
    end

    it "defaults to empty variables and headers" do
      job = build_test_job
      expect(job.variables).to be_empty
      expect(job.headers).to be_empty
    end

    it "uses the provided bpmn_process_id" do
      job = build_test_job(bpmn_process_id: "my-process")
      expect(job.bpmn_process_id).to eq("my-process")
    end

    it "uses the provided retries count" do
      job = build_test_job(retries: 5)
      expect(job.retries).to eq(5)
    end

    describe "stub client operations" do
      it "accepts complete!" do
        job = build_test_job
        expect { job.complete!(result: "ok") }.not_to raise_error
        expect(job).to be_complete
      end

      it "accepts fail!" do
        job = build_test_job
        expect { job.fail!("something went wrong") }.not_to raise_error
        expect(job).to be_failed
      end

      it "accepts throw_bpmn_error!" do
        job = build_test_job
        expect { job.throw_bpmn_error!(:not_found, "gone") }.not_to raise_error
        expect(job).to be_error
      end

      it "accepts update_retries" do
        job = build_test_job
        expect { job.update_retries(5) }.not_to raise_error
      end

      it "accepts update_timeout" do
        job = build_test_job
        expect { job.update_timeout(30_000) }.not_to raise_error
      end
    end
  end

  describe "#execute_worker" do
    context "with keyword arguments" do
      it "returns the perform result" do
        result = execute_worker(worker_class, variables: { order_id: 1 })
        expect(result).to eq(status: "done")
      end

      it "auto-completes the job by default" do
        job = build_test_job(variables: { order_id: 1 })
        execute_worker(worker_class, job: job)
        expect(job).to be_complete
      end
    end

    context "with a pre-built job" do
      it "uses the provided job" do
        job = build_test_job(variables: { order_id: 1 })
        result = execute_worker(worker_class, job: job)
        expect(result).to eq(status: "done")
        expect(job).to be_complete
      end
    end

    context "when job: is mixed with other kwargs" do
      it "raises ArgumentError" do
        job = build_test_job
        expect do
          execute_worker(worker_class, job: job, variables: { foo: 1 })
        end.to raise_error(ArgumentError, /Cannot pass job: together with/)
      end
    end

    context "when the worker raises an error" do
      let(:failing_worker) do
        Class.new(Busybee::Worker) do
          job_type "failing-worker"

          def perform
            raise StandardError, "kaboom"
          end
        end
      end

      it "re-raises the error" do
        expect do
          execute_worker(failing_worker)
        end.to raise_error(StandardError, "kaboom")
      end

      it "marks the job as failed before re-raising" do
        job = build_test_job
        expect do
          execute_worker(failing_worker, job: job)
        end.to raise_error(StandardError, "kaboom")
        expect(job).to be_failed
      end
    end

    context "with fail_job_on_error disabled" do
      let(:no_auto_fail_worker) do
        Class.new(Busybee::Worker) do
          job_type "no-auto-fail"
          fail_job_on_error false

          def perform
            raise StandardError, "kaboom"
          end
        end
      end

      it "re-raises the error" do
        expect do
          execute_worker(no_auto_fail_worker)
        end.to raise_error(StandardError, "kaboom")
      end

      it "does not mark the job as failed" do
        job = build_test_job
        expect do
          execute_worker(no_auto_fail_worker, job: job)
        end.to raise_error(StandardError, "kaboom")
        expect(job).to be_ready
      end
    end

    context "with complete_job_on_success disabled" do
      let(:no_autocomplete_worker) do
        Class.new(Busybee::Worker) do
          job_type "no-autocomplete"
          complete_job_on_success false

          def perform
            { status: "pending_review" }
          end
        end
      end

      it "returns the result but leaves job as ready" do
        job = build_test_job
        result = execute_worker(no_autocomplete_worker, job: job)
        expect(result).to eq(status: "pending_review")
        expect(job).to be_ready
      end
    end

    context "with input validation" do
      let(:validated_worker) do
        Class.new(Busybee::Worker) do
          job_type "validated-worker"
          variable :order_id, required: true

          def perform
            { order_id: order_id }
          end
        end
      end

      it "raises MissingInput when required variables are absent" do
        expect do
          execute_worker(validated_worker, variables: {})
        end.to raise_error(Busybee::MissingInput, /order_id/)
      end

      it "succeeds when required variables are present" do
        result = execute_worker(validated_worker, variables: { order_id: 42 })
        expect(result).to eq(order_id: 42)
      end
    end

    context "when the worker manually completes the job" do
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

      it "marks the job as complete" do
        job = build_test_job
        execute_worker(manual_complete_worker, job: job)
        expect(job).to be_complete
      end
    end

    context "when the worker throws a BPMN error" do
      let(:bpmn_error_worker) do
        Class.new(Busybee::Worker) do
          job_type "bpmn-error"

          def perform
            throw_bpmn_error!(:not_found, "order missing")
          end
        end
      end

      it "marks the job as error and skips auto-complete" do
        job = build_test_job
        execute_worker(bpmn_error_worker, job: job)
        expect(job).to be_error
      end
    end
  end
end
