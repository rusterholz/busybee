# frozen_string_literal: true

require "busybee/testing"

RSpec.describe Busybee::Testing::Helpers::Execution do
  let(:worker_class) do
    Class.new(Busybee::Worker) do
      job_type "test-worker"
      strict_outputs false

      def perform
        { status: "done" }
      end
    end
  end

  describe "#execute_worker" do
    context "with keyword arguments" do
      it "builds a job of the worker's type from them, runs it, and returns it" do
        job = execute_worker(worker_class, variables: { order_id: 1 })

        expect(job).to be_a(Busybee::Job).and be_complete
        expect(job).to have_attributes(type: "test-worker", variables: { "order_id" => 1 })
      end

      it "keeps perform's result on the job" do
        expect(execute_worker(worker_class).result).to eq("status" => "done")
      end
    end

    context "with a pre-built job" do
      it "runs that job and returns it" do
        job = build_test_job(type: "test-worker")

        expect(execute_worker(worker_class, job: job)).to be(job)
        expect(job).to be_complete
      end
    end

    context "with several jobs" do
      it "runs them in order and returns them" do
        client = build_test_client
        jobs = Array.new(2) { build_test_job(type: "test-worker", client: client) }

        expect(execute_worker(worker_class, jobs: jobs)).to eq(jobs)
        expect(client.received(:complete_job).map(&:jobKey)).to eq(jobs.map(&:key))
      end

      it "refuses jobs that resolve through different clients" do
        jobs = Array.new(2) { build_test_job(type: "test-worker") }

        expect { execute_worker(worker_class, jobs: jobs) }.to raise_error(ArgumentError, /same client/)
      end
    end

    context "when the ways of naming the job are mixed" do
      it "refuses job: with job-building keywords" do
        expect { execute_worker(worker_class, job: build_test_job, variables: { foo: 1 }) }.
          to raise_error(ArgumentError, /only one of/)
      end

      it "refuses job: with jobs:" do
        expect { execute_worker(worker_class, job: build_test_job, jobs: [build_test_job]) }.
          to raise_error(ArgumentError, /only one of/)
      end
    end

    describe "which hooks fire" do
      let(:fired) { [] }

      around do |example|
        with_isolated_hooks do
          %i[on_worker_started on_job_activated after_perform after_call on_worker_shutdown].each do |type|
            Busybee::Hooks.register(type, ->(_) { fired << type })
          end
          example.run
        end
      end

      it "fires every level for a worker class: worker, job, perform and call" do
        execute_worker(worker_class)

        expect(fired).to eq(%i[on_worker_started on_job_activated after_call after_perform on_worker_shutdown])
      end

      it "fires no worker moment over a started worker, and leaves it running" do
        worker = start_test_worker(worker_class)
        fired.clear

        execute_worker(worker, variables: { order_id: 1 })

        expect(fired).to eq(%i[on_job_activated after_call after_perform])
        expect(worker).to be_running
      end

      it "fires only what without_hooks leaves" do
        without_hooks(:worker, :call) { execute_worker(worker_class) }

        expect(fired).to eq(%i[on_job_activated after_perform])
      end
    end

    context "with a started worker" do
      it "builds keyword jobs on the worker's own client" do
        worker = start_test_worker(worker_class)

        job = execute_worker(worker, variables: { order_id: 1 })

        expect(job.client).to be(worker.client)
        expect(job).to be_complete
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

      it "fails the job and keeps the error on it, raising nothing" do
        job = execute_worker(failing_worker)

        expect(job).to be_failed
        expect(job.error).to be_a(StandardError).and have_attributes(message: "kaboom")
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

      it "leaves the job ready, its result recorded" do
        job = execute_worker(no_autocomplete_worker)

        expect(job).to be_ready
        expect(job.result).to eq("status" => "pending_review")
      end
    end

    context "with input validation" do
      let(:validated_worker) do
        Class.new(Busybee::Worker) do
          job_type "validated-worker"
          variable :order_id, required: true
          strict_outputs false

          def perform
            { order_id: order_id }
          end
        end
      end

      it "fails the job with MissingInput when required variables are absent" do
        job = execute_worker(validated_worker, variables: {})

        expect(job).to be_failed
        expect(job.error).to be_a(Busybee::MissingInput).and have_attributes(message: /order_id/)
      end

      it "succeeds when required variables are present" do
        expect(execute_worker(validated_worker, variables: { order_id: 42 }).result).to eq("order_id" => 42)
      end
    end

    context "when the worker manually completes the job" do
      let(:manual_complete_worker) do
        Class.new(Busybee::Worker) do
          job_type "manual-complete"
          complete_job_on_success false
          strict_outputs false

          def perform
            complete!(tracking: "ABC123")
            { status: "shipped" }
          end
        end
      end

      it "completes the job with what was sent, not what perform returned" do
        job = execute_worker(manual_complete_worker)

        expect(job).to be_complete
        expect(job.result).to eq("tracking" => "ABC123")
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
        expect(execute_worker(bpmn_error_worker)).to be_error
      end
    end
  end
end
