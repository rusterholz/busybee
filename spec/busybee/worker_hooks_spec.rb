# frozen_string_literal: true

# Tests for how Busybee::Worker wires into the Busybee::Hooks system during
# perform_job. Unit tests for the hooks module live in hooks_spec.rb; this
# file exercises the integration surface where workers build events, push
# context, and invoke before_job/around_job at the right moments.

RSpec.describe Busybee::Worker do
  context "with hook integration" do
    let(:client) { instance_double(Busybee::Client) }

    let(:raw_job) do
      # rubocop:disable RSpec/VerifiedDoubles
      double(
        "Busybee::GRPC::ActivatedJob",
        key: 123456,
        type: "process_order",
        processInstanceKey: 789012,
        bpmnProcessId: "order-workflow",
        elementId: "service_task_1",
        retries: 3,
        deadline: 1640000000000,
        variables: '{"order_id":"abc-123"}',
        customHeaders: '{"priority":"high"}'
      )
      # rubocop:enable RSpec/VerifiedDoubles
    end

    let(:job) { Busybee::Job.new(raw_job, client: client) }

    let(:performing_worker) do
      stub_const("HookedWorker", Class.new(Busybee::Worker) do
        strict_outputs false
        define_method(:perform) { { processed: true } }
      end)
    end

    before do
      allow(client).to receive(:complete_job)
      allow(client).to receive(:fail_job)
      allow(client).to receive(:throw_bpmn_error)
    end

    after { Busybee::Hooks.reset! }

    describe "timestamps" do
      it "stamps execution_started_at during perform_job" do
        performing_worker.perform_job(job)
        expect(job.execution_started_at(:monotonic)).to be_a(Float)
        expect(job.execution_started_at).to be_a(Time)
      end

      it "stamps perform_started_at and perform_finished_at around perform" do
        performing_worker.perform_job(job)
        expect(job.perform_started_at).to be_a(Time)
        expect(job.perform_finished_at).to be_a(Time)
        expect(job.perform_finished_at).to be >= job.perform_started_at
      end

      it "stamps resolved_at when job completes" do
        performing_worker.perform_job(job)
        expect(job.resolved_at).to be_a(Time)
        expect(job.resolved_at).to be >= job.perform_finished_at
      end

      it "stamps resolved_at when job fails" do
        worker = stub_const("FailWorker", Class.new(Busybee::Worker) do
          define_method(:perform) { raise "boom" }
        end)
        worker.perform_job(job)
        expect(job.resolved_at).to be_a(Time)
      end

      it "stamps resolved_at when job throws BPMN error" do
        worker = stub_const("BpmnWorker", Class.new(Busybee::Worker) do
          define_method(:perform) { throw_bpmn_error!(:not_found, "missing") }
        end)
        worker.perform_job(job)
        expect(job.resolved_at).to be_a(Time)
      end

      it "stamps perform timestamps inside the around_job chain (after middleware preamble)" do
        middleware_timestamp = nil
        Busybee.around_job do |_job, perform|
          middleware_timestamp = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          perform.call
        end

        performing_worker.perform_job(job)
        expect(job.perform_started_at).to be >= middleware_timestamp
      end
    end

    describe "before_job hooks" do
      it "fires before perform with the Job in :ready status" do
        captured_status = nil
        Busybee.before_job do |job|
          captured_status = job.status
        end

        performing_worker.perform_job(job)

        expect(captured_status).to eq(:ready)
      end

      it "passes the Job with its identity keys reachable" do
        received_job = nil
        Busybee.before_job { |job| received_job = job }

        performing_worker.perform_job(job)

        aggregate_failures do
          expect(received_job).to be(job)
          expect(received_job.type).to eq("process_order")
          expect(received_job.worker_class).to eq(performing_worker)
          expect(received_job.key).to eq(123456)
          expect(received_job.bpmn_process_id).to eq("order-workflow")
          expect(received_job.process_instance_key).to eq(789012)
          expect(received_job.element_id).to eq("service_task_1")
        end
      end

      it "fires before perform (ordering)" do
        sequence = []
        Busybee.before_job { sequence << :hook }
        worker = stub_const("SequenceWorker", Class.new(Busybee::Worker) do
          strict_outputs false
          define_method(:perform) do
            sequence << :perform
            { done: true }
          end
        end)

        worker.perform_job(job)
        expect(sequence).to eq(%i[hook perform])
      end

      it "exposes the worker instance on the Job" do
        received_worker = nil
        Busybee.before_job { |job| received_worker = job.worker }

        performing_worker.perform_job(job)
        expect(received_worker).to be_a(performing_worker)
      end

      it "propagates errors to perform_job rescue (triggers autofail)" do
        Busybee.before_job { raise "hook boom" }

        performing_worker.perform_job(job)
        expect(client).to have_received(:fail_job).with(123456, /hook boom/, retries: nil, backoff: nil)
      end

      it "prevents status changes during before_job hooks" do
        Busybee.before_job { |job| job.complete!({ early: true }) }

        expect { performing_worker.perform_job(job) }.to raise_error(Busybee::StatusChangeOutsidePerform)
        expect(job).to be_failed
      end

      it "clears flag on rescue entry so autofail works after hook error" do
        Busybee.before_job { raise "hook boom" }

        performing_worker.perform_job(job)
        expect(job).to be_failed
      end

      it "triggers Shutdown when hook raises a shutdown_on error" do
        worker = stub_const("ShutdownHookWorker", Class.new(Busybee::Worker) do
          shutdown_on RuntimeError
          strict_outputs false
          define_method(:perform) { { done: true } }
        end)
        Busybee.before_job { raise "db gone" }

        expect { worker.perform_job(job) }.to raise_error(Busybee::Worker::Shutdown)
      end

      it "respects prefiltering" do
        results = []
        Busybee.before_job(worker_class: /Nonexistent/) { results << :filtered }
        Busybee.before_job { results << :unfiltered }

        performing_worker.perform_job(job)
        expect(results).to eq([:unfiltered])
      end
    end

    describe "around_job hooks" do
      it "wraps perform (before/core/after ordering)" do
        sequence = []
        Busybee.around_job do |_job, perform|
          sequence << :before
          perform.call
          sequence << :after
        end
        worker = stub_const("AroundWorker", Class.new(Busybee::Worker) do
          strict_outputs false
          define_method(:perform) do
            sequence << :perform
            { done: true }
          end
        end)

        worker.perform_job(job)
        expect(sequence).to eq(%i[before perform after])
      end

      it "captures perform return value onto job.result by the time around-yield returns" do
        captured_result = nil
        Busybee.around_job do |job, perform|
          perform.call
          captured_result = job.result
        end

        performing_worker.perform_job(job)
        expect(captured_result).to eq("processed" => true)
      end

      it "does not overwrite result when perform calls complete! manually" do
        captured_result = nil
        Busybee.around_job do |job, perform|
          perform.call
          captured_result = job.result
        end
        worker = stub_const("ManualCompleteResultWorker", Class.new(Busybee::Worker) do
          strict_outputs false
          define_method(:perform) do
            complete!({ manual: true })
            nil # perform returns nil, but result should be from complete!
          end
        end)

        worker.perform_job(job)
        expect(captured_result).to eq("manual" => true)
      end

      it "works even when middleware forgets to return result" do
        Busybee.around_job do |_job, perform|
          perform.call
          "forgot to return result"
        end

        performing_worker.perform_job(job)
        expect(client).to have_received(:complete_job).with(123456, vars: { "processed" => true })
      end

      it "prevents status changes during around_job preamble (before perform.call)" do
        worker = stub_const("PrematureCompleteWorker", Class.new(Busybee::Worker) do
          strict_outputs false
          define_method(:perform) { { done: true } }
        end)
        Busybee.around_job do |_job, perform|
          job.complete!({ early: true }) # should raise
          perform.call
        end

        expect { worker.perform_job(job) }.to raise_error(Busybee::StatusChangeOutsidePerform)
        expect(job).to be_failed
      end

      it "prevents status changes during around_job after-yield (after perform.call)" do
        worker = stub_const("LateCompleteWorker", Class.new(Busybee::Worker) do
          strict_outputs false
          define_method(:perform) { { done: true } }
        end)
        Busybee.around_job do |_job, perform|
          perform.call
          job.complete!({ late: true }) # should raise — flag re-engages after perform
        end

        expect { worker.perform_job(job) }.to raise_error(Busybee::StatusChangeOutsidePerform)
        expect(job).to be_failed
      end

      it "allows status changes inside perform (flag cleared)" do
        worker = stub_const("ManualCompleteInPerform", Class.new(Busybee::Worker) do
          strict_outputs false
          define_method(:perform) do
            complete!({ manual: true })
          end
        end)

        expect { worker.perform_job(job) }.not_to raise_error
        expect(job).to be_complete
      end
    end

    describe "after_job hooks" do
      it "fires after auto-complete with status :complete" do
        received_job = nil
        Busybee.after_job { |job| received_job = job }

        performing_worker.perform_job(job)

        expect(received_job.status).to eq(:complete)
        expect(received_job).to be_completed
      end

      it "fires after manual complete inside perform" do
        received_job = nil
        Busybee.after_job { |job| received_job = job }
        worker = stub_const("ManualAfterWorker", Class.new(Busybee::Worker) do
          strict_outputs false
          define_method(:perform) { complete!({ manual: true }) }
        end)

        worker.perform_job(job)
        expect(received_job.status).to eq(:complete)
      end

      it "receives the same Job as before_job (it's the same Job object)" do
        before_job_arg = nil
        after_job_arg = nil
        Busybee.before_job { |j| before_job_arg = j }
        Busybee.after_job { |j| after_job_arg = j }

        performing_worker.perform_job(job)
        expect(after_job_arg).to be(before_job_arg)
      end

      it "includes result from complete! vars" do
        received_result = nil
        Busybee.after_job { |job| received_result = job.result }

        performing_worker.perform_job(job)
        expect(received_result).to eq("processed" => true)
      end

      it "exposes timestamps on the Job" do
        received_job = nil
        Busybee.after_job { |job| received_job = job }

        performing_worker.perform_job(job)
        expect(received_job.execution_started_at(:monotonic)).to be_a(Float)
        expect(received_job.resolved_at(:monotonic)).to be_a(Float)
      end

      it "fires after auto-fail with status :failed and error" do
        received_job = nil
        Busybee.after_job { |job| received_job = job }
        worker = stub_const("FailingAfterWorker", Class.new(Busybee::Worker) do
          define_method(:perform) { raise "boom" }
        end)

        worker.perform_job(job)

        expect(received_job.status).to eq(:failed)
        expect(received_job).to be_failed
        expect(received_job.error).to be_a(RuntimeError)
        expect(received_job.error_message).to eq("boom")
      end

      it "fires after fail! with string error message" do
        received_job = nil
        Busybee.after_job { |job| received_job = job }
        worker = stub_const("StringFailWorker", Class.new(Busybee::Worker) do
          define_method(:perform) { fail!("custom message") }
        end)

        worker.perform_job(job)

        expect(received_job.status).to eq(:failed)
        expect(received_job.error_message).to eq("custom message")
      end

      it "swallows errors in after_job hooks and logs them" do
        logger = instance_double(Logger, error: nil)
        allow(Busybee).to receive(:logger).and_return(logger)
        Busybee.after_job { raise "hook boom" }

        expect { performing_worker.perform_job(job) }.not_to raise_error
        expect(job).to be_complete
        expect(logger).to have_received(:error).
          with(%r{\[busybee\] Error in hooks \(ignored\): \[RuntimeError\] hook boom \(at .+/worker_hooks_spec\.rb:\d+})
      end

      it "propagates shutdown_on errors from after_job hooks" do
        worker = stub_const("ShutdownAfterWorker", Class.new(Busybee::Worker) do
          shutdown_on RuntimeError
          strict_outputs false
          define_method(:perform) { { done: true } }
        end)
        Busybee.after_job { raise "db gone" }

        expect { worker.perform_job(job) }.to raise_error(Busybee::Worker::Shutdown)
      end

      it "prefilters by status — after_job(status: :failed) skips completed jobs" do
        results = []
        Busybee.after_job(status: :failed) { results << :failed_only }
        Busybee.after_job { results << :all }

        performing_worker.perform_job(job)
        expect(results).to eq([:all])
      end

      it "prefilters by status — after_job(status: :failed) fires for failed jobs" do
        results = []
        Busybee.after_job(status: :failed) { results << :failed_only }
        worker = stub_const("PrefilterFailWorker", Class.new(Busybee::Worker) do
          define_method(:perform) { raise "boom" }
        end)

        worker.perform_job(job)
        expect(results).to eq([:failed_only])
      end

      it "fires after throw_bpmn_error! with error code" do
        received_job = nil
        Busybee.after_job { |job| received_job = job }
        worker = stub_const("BpmnAfterWorker", Class.new(Busybee::Worker) do
          define_method(:perform) { throw_bpmn_error!(:not_found, "missing") }
        end)

        worker.perform_job(job)

        expect(received_job.status).to eq(:error)
        expect(received_job).to be_errored
        expect(received_job.error_code).to eq("NOT_FOUND")
        expect(received_job.error_message).to eq("missing")
      end
    end

    describe "handle_failure logging" do
      it "logs a warning when perform raises after manual completion" do
        logger = instance_double(Logger, warn: nil)
        allow(Busybee).to receive(:logger).and_return(logger)
        worker = stub_const("CompleteAndRaiseWorker", Class.new(Busybee::Worker) do
          strict_outputs false
          define_method(:perform) do
            complete!({ done: true })
            raise "post-complete error"
          end
        end)

        worker.perform_job(job)
        expect(logger).to have_received(:warn).
          with(%r{already complete: \[RuntimeError\] post-complete error \(at .+/worker_hooks_spec\.rb:\d+})
      end

      it "does not log the already-handled warning when fail_job_on_error is false" do
        logger = instance_double(Logger, warn: nil)
        allow(Busybee).to receive(:logger).and_return(logger)
        worker = stub_const("NoAutoFailLogWorker", Class.new(Busybee::Worker) do
          fail_job_on_error false
          strict_outputs false
          define_method(:perform) do
            complete!({ done: true })
            raise "post-complete error"
          end
        end)

        worker.perform_job(job)
        expect(logger).not_to have_received(:warn).with(/already complete/)
      end
    end

    describe "around_job hooks (continued)" do
      it "fires before_job before around_job" do
        sequence = []
        Busybee.before_job { sequence << :before }
        Busybee.around_job do |_job, perform|
          sequence << :around
          perform.call
        end

        performing_worker.perform_job(job)
        expect(sequence).to eq(%i[before around])
      end
    end
  end
end
