# frozen_string_literal: true

RSpec.describe Busybee::Worker do
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

  let(:minimal_worker) do
    stub_const("MinimalWorker", Class.new(described_class))
  end

  let(:performing_worker) do
    stub_const("PerformingWorker", Class.new(described_class) do
      strict_outputs false
      define_method(:perform) do
        { processed: true }
      end
    end)
  end

  describe ".perform_job" do
    before { allow(client).to receive(:complete_job) }

    it "calls perform on a new instance and returns the result hash" do
      expect(performing_worker.perform_job(job)).to eq("processed" => true)
    end

    it "raises NotImplementedError when perform is not overridden" do
      expect { minimal_worker.perform_job(job) }.to raise_error(NotImplementedError, /perform/)
    end

    context "with complete_job_on_success (default: true)" do
      it "auto-completes the job with the result hash" do
        performing_worker.perform_job(job)
        expect(client).to have_received(:complete_job).with(123456, vars: { processed: true })
      end

      it "normalizes non-hash results to empty hash" do
        worker = stub_const("NilReturnWorker", Class.new(described_class) do
          define_method(:perform) { nil }
        end)

        worker.perform_job(job)
        expect(client).to have_received(:complete_job).with(123456, vars: {})
      end

      it "skips completion when disabled" do
        worker = stub_const("NoAutoCompleteWorker", Class.new(described_class) do
          complete_job_on_success false
          define_method(:perform) { { done: true } }
        end)

        worker.perform_job(job)
        expect(client).not_to have_received(:complete_job)
      end

      it "skips completion when job is already handled" do
        worker = stub_const("ManualCompleteWorker", Class.new(described_class) do
          strict_outputs false
          define_method(:perform) do
            complete!(manual: true)
            { extra: "data" }
          end
        end)

        worker.perform_job(job)
        expect(client).to have_received(:complete_job).once.with(123456, vars: { manual: true })
      end

      it "logs and swallows GRPC errors from complete!" do
        allow(client).to receive(:complete_job).and_raise(GRPC::Unavailable, "connection lost")
        logger = instance_double(Logger, warn: nil)
        allow(Busybee).to receive(:logger).and_return(logger)

        expect { performing_worker.perform_job(job) }.not_to raise_error
        expect(logger).to have_received(:warn).with(/Failed to complete job.*connection lost/)
      end
    end

    context "with fail_job_on_error (default: true)" do
      before { allow(client).to receive(:fail_job) }

      it "auto-fails the job when perform raises" do
        worker = stub_const("FailingWorker", Class.new(described_class) do
          define_method(:perform) { raise "boom" }
        end)

        worker.perform_job(job)
        expect(client).to have_received(:fail_job).with(123456, /RuntimeError.*boom/, retries: nil, backoff: nil)
      end

      it "uses configured backoff" do
        worker = stub_const("BackoffWorker", Class.new(described_class) do
          backoff 30_000
          define_method(:perform) { raise "boom" }
        end)

        worker.perform_job(job)
        expect(client).to have_received(:fail_job).with(123456, anything, retries: nil, backoff: 30_000)
      end

      it "does not auto-fail when disabled" do
        logger = instance_double(Logger, warn: nil)
        allow(Busybee).to receive(:logger).and_return(logger)

        worker = stub_const("NoAutoFailWorker", Class.new(described_class) do
          fail_job_on_error false
          define_method(:perform) { raise "boom" }
        end)

        expect { worker.perform_job(job) }.not_to raise_error
        expect(client).not_to have_received(:fail_job)
      end

      it "skips auto-fail when job is already handled" do
        worker = stub_const("ManualFailWorker", Class.new(described_class) do
          define_method(:perform) do
            fail!("handled manually", retries: 0)
            raise "after fail"
          end
        end)

        worker.perform_job(job)
        expect(client).to have_received(:fail_job).once.with(123456, "handled manually", retries: 0, backoff: nil)
      end

      it "skips auto-fail when job had a BPMN error thrown" do
        allow(client).to receive(:throw_bpmn_error)

        worker = stub_const("BpmnErrorWorker", Class.new(described_class) do
          define_method(:perform) do
            throw_bpmn_error!(:order_not_found, "missing")
            raise "after bpmn error"
          end
        end)

        worker.perform_job(job)
        expect(client).not_to have_received(:fail_job)
      end

      it "logs and swallows GRPC errors from fail!" do
        allow(client).to receive(:fail_job).and_raise(GRPC::Unavailable, "connection lost")
        logger = instance_double(Logger, warn: nil)
        allow(Busybee).to receive(:logger).and_return(logger)

        worker = stub_const("FailGrpcWorker", Class.new(described_class) do
          define_method(:perform) { raise "boom" }
        end)

        expect { worker.perform_job(job) }.not_to raise_error
        expect(logger).to have_received(:warn).with(/Failed to fail job.*connection lost/)
      end

      it "swallows perform errors after auto-fail (runner continues)" do
        worker = stub_const("SwallowWorker", Class.new(described_class) do
          define_method(:perform) { raise "transient" }
        end)

        expect { worker.perform_job(job) }.not_to raise_error
      end

      it "swallows errors when fail_job_on_error is false and logs a warning" do
        logger = instance_double(Logger, warn: nil)
        allow(Busybee).to receive(:logger).and_return(logger)

        worker = stub_const("SwallowNoFailWorker", Class.new(described_class) do
          fail_job_on_error false
          define_method(:perform) { raise "unhandled" }
        end)

        expect { worker.perform_job(job) }.not_to raise_error
        expect(job).to be_ready
        expect(logger).to have_received(:warn).with(
          Regexp.new("Unhandled error.*fail_job_on_error is off.*" \
                     "\\[RuntimeError\\] unhandled \\(at .+/worker_spec\\.rb:\\d+.+" \
                     "\\. Job will timeout and retry\\.")
        )
      end
    end

    context "with shutdown_on" do
      before do
        stub_const("PGConnectionBad", Class.new(StandardError))
        allow(client).to receive(:fail_job)
      end

      it "wraps matching exceptions as Shutdown and re-raises" do
        worker = stub_const("ShutdownWorker", Class.new(described_class) do
          shutdown_on PGConnectionBad
          define_method(:perform) { raise PGConnectionBad, "connection lost" }
        end)

        expect { worker.perform_job(job) }.to raise_error(Busybee::Worker::Shutdown) do |e|
          expect(e.cause).to be_a(PGConnectionBad)
          expect(e.worker_class).to eq(worker)
          expect(e.message).to include("PGConnectionBad")
          expect(e.message).to include("connection lost")
        end
      end

      it "auto-fails the job before raising Shutdown" do
        worker = stub_const("FailThenShutdownWorker", Class.new(described_class) do
          shutdown_on PGConnectionBad
          define_method(:perform) { raise PGConnectionBad, "gone" }
        end)

        expect { worker.perform_job(job) }.to raise_error(Busybee::Worker::Shutdown)
        expect(client).to have_received(:fail_job).with(123456, /PGConnectionBad.*gone/, retries: nil, backoff: nil)
      end

      it "does not wrap non-matching exceptions" do
        worker = stub_const("NonMatchWorker", Class.new(described_class) do
          shutdown_on PGConnectionBad
          define_method(:perform) { raise "normal error" }
        end)

        expect { worker.perform_job(job) }.not_to raise_error
      end

      it "matches subclasses" do
        stub_const("PGQueryCancelled", Class.new(PGConnectionBad))

        worker = stub_const("SubclassShutdownWorker", Class.new(described_class) do
          shutdown_on PGConnectionBad
          define_method(:perform) { raise PGQueryCancelled, "cancelled" }
        end)

        expect { worker.perform_job(job) }.to raise_error(Busybee::Worker::Shutdown)
      end

      it "re-raises Shutdown raised directly in perform" do
        worker = stub_const("DirectShutdownWorker", Class.new(described_class) do
          define_method(:perform) { raise Busybee::Worker::Shutdown.new(worker: self.class) }
        end)

        expect { worker.perform_job(job) }.to raise_error(Busybee::Worker::Shutdown)
      end

      it "auto-fails using the cause when Shutdown is raised directly" do
        worker = stub_const("DirectShutdownFailWorker", Class.new(described_class) do
          define_method(:perform) do
            raise "root cause"
          rescue StandardError
            raise Busybee::Worker::Shutdown.new(worker: self.class)
          end
        end)

        expect { worker.perform_job(job) }.to raise_error(Busybee::Worker::Shutdown)
        expect(client).to have_received(:fail_job).with(123456, /RuntimeError.*root cause/, retries: nil, backoff: nil)
      end

      it "merges gem-level shutdown_on_errors" do
        original = Busybee.shutdown_on_errors.dup
        begin
          Busybee.shutdown_on_errors = [PGConnectionBad]

          worker = stub_const("GemLevelWorker", Class.new(described_class) do
            define_method(:perform) { raise PGConnectionBad, "gone" }
          end)

          expect { worker.perform_job(job) }.to raise_error(Busybee::Worker::Shutdown)
        ensure
          Busybee.shutdown_on_errors = original
        end
      end
    end

    context "with input validation" do
      before { allow(client).to receive(:fail_job) }

      it "raises MissingInput for missing required inputs" do
        worker = stub_const("RequiredInputWorker", Class.new(described_class) do
          variable :nonexistent, required: true
          define_method(:perform) { {} }
        end)

        expect { worker.perform_job(job) }.not_to raise_error
        expect(client).to have_received(:fail_job).
          with(123456, /MissingInput.*:nonexistent/, retries: nil, backoff: nil)
      end

      it "lists all missing inputs" do
        worker = stub_const("MultiMissingWorker", Class.new(described_class) do
          variable :missing_one, required: true
          variable :missing_two, required: true
          define_method(:perform) { {} }
        end)

        expect { worker.perform_job(job) }.not_to raise_error
        expect(client).to have_received(:fail_job).with(123456, /missing_one.*missing_two/, retries: nil, backoff: nil)
      end

      it "passes when required inputs are present" do
        worker = stub_const("PresentInputWorker", Class.new(described_class) do
          variable :order_id, required: true
          strict_outputs false
          define_method(:perform) { { ok: true } }
        end)

        expect { worker.perform_job(job) }.not_to raise_error
      end

      it "skips validation for inputs with defaults" do
        worker = stub_const("DefaultInputWorker", Class.new(described_class) do
          variable :nonexistent, default: "fallback"
          strict_outputs false
          define_method(:perform) { { ok: true } }
        end)

        expect { worker.perform_job(job) }.not_to raise_error
        expect(client).not_to have_received(:fail_job)
      end

      it "includes job_type in error message" do
        worker = stub_const("TypedWorker", Class.new(described_class) do
          job_type "process-order"
          variable :nonexistent, required: true
          define_method(:perform) { {} }
        end)

        expect { worker.perform_job(job) }.not_to raise_error
        expect(client).to have_received(:fail_job).with(123456, /process-order worker/, retries: nil, backoff: nil)
      end
    end

    context "with output validation" do
      before { allow(client).to receive(:complete_job) }

      it "raises MissingOutput when required outputs are absent" do
        allow(client).to receive(:fail_job)

        worker = stub_const("MissingOutputWorker", Class.new(described_class) do
          output :notification_id, required: true
          define_method(:perform) { {} }
        end)

        expect { worker.perform_job(job) }.not_to raise_error
        expect(client).not_to have_received(:complete_job)
        expect(client).to have_received(:fail_job).
          with(123456, /MissingOutput.*:notification_id/, retries: nil, backoff: nil)
      end

      it "passes when required outputs are present as symbols" do
        worker = stub_const("SymbolOutputWorker", Class.new(described_class) do
          output :notification_id, required: true
          define_method(:perform) { { notification_id: "abc" } }
        end)

        worker.perform_job(job)
        expect(client).to have_received(:complete_job).with(123456, vars: { notification_id: "abc" })
      end

      it "passes when required outputs are present as strings" do
        worker = stub_const("StringOutputWorker", Class.new(described_class) do
          output :notification_id, required: true
          define_method(:perform) { { "notification_id" => "abc" } }
        end)

        worker.perform_job(job)
        expect(client).to have_received(:complete_job)
      end

      it "skips output validation when complete_job_on_success is false" do
        worker = stub_const("NoCompleteOutputWorker", Class.new(described_class) do
          complete_job_on_success false
          output :notification_id, required: true
          define_method(:perform) { {} }
        end)

        expect { worker.perform_job(job) }.not_to raise_error
        expect(client).not_to have_received(:complete_job)
      end

      it "skips output validation for optional outputs" do
        worker = stub_const("OptionalOutputWorker", Class.new(described_class) do
          output :debug_info, required: false
          define_method(:perform) { {} }
        end)

        worker.perform_job(job)
        expect(client).to have_received(:complete_job).with(123456, vars: {})
      end
    end

    context "with strict output validation" do
      before { allow(client).to receive(:complete_job) }

      it "raises UndeclaredOutput for keys not in the output DSL" do
        allow(client).to receive(:fail_job)

        worker = stub_const("UndeclaredWorker", Class.new(described_class) do
          output :status
          define_method(:perform) { { status: "ok", extra: "surprise" } }
        end)

        expect { worker.perform_job(job) }.not_to raise_error
        expect(client).not_to have_received(:complete_job)
        expect(client).to have_received(:fail_job).
          with(123456, /UndeclaredOutput.*:extra/, retries: nil, backoff: nil)
      end

      it "passes when all returned keys are declared" do
        worker = stub_const("DeclaredWorker", Class.new(described_class) do
          output :status
          output :count
          define_method(:perform) { { status: "ok", count: 5 } }
        end)

        worker.perform_job(job)
        expect(client).to have_received(:complete_job)
      end

      it "matches string keys against symbol output names" do
        worker = stub_const("StringKeyWorker", Class.new(described_class) do
          output :status
          define_method(:perform) { { "status" => "ok" } }
        end)

        worker.perform_job(job)
        expect(client).to have_received(:complete_job)
      end

      it "allows any keys when strict_outputs is false per-worker" do
        worker = stub_const("LenientWorker", Class.new(described_class) do
          strict_outputs false
          output :status
          define_method(:perform) { { status: "ok", extra: "allowed" } }
        end)

        worker.perform_job(job)
        expect(client).to have_received(:complete_job).with(123456, vars: { status: "ok", extra: "allowed" })
      end

      it "allows any keys when strict_outputs is false gem-wide" do
        original = Busybee.instance_variable_get(:@default_strict_outputs)
        Busybee.default_strict_outputs = false

        worker = stub_const("GemLenientWorker", Class.new(described_class) do
          output :status
          define_method(:perform) { { status: "ok", bonus: true } }
        end)

        worker.perform_job(job)
        expect(client).to have_received(:complete_job)
      ensure
        Busybee.default_strict_outputs = original
      end

      it "skips validation when complete_job_on_success is false (manual completion)" do
        worker = stub_const("ManualCompleteWorker", Class.new(described_class) do
          complete_job_on_success false
          output :status
          define_method(:perform) { { status: "ok", extra: "ignored" } }
        end)

        expect { worker.perform_job(job) }.not_to raise_error
        expect(client).not_to have_received(:complete_job)
      end

      it "passes when worker has no declared outputs and returns empty hash" do
        worker = stub_const("NoOutputWorker", Class.new(described_class) do
          define_method(:perform) { {} }
        end)

        worker.perform_job(job)
        expect(client).to have_received(:complete_job)
      end

      it "raises when worker has no declared outputs but returns keys" do
        allow(client).to receive(:fail_job)

        worker = stub_const("SurpriseOutputWorker", Class.new(described_class) do
          define_method(:perform) { { unexpected: true } }
        end)

        expect { worker.perform_job(job) }.not_to raise_error
        expect(client).not_to have_received(:complete_job)
        expect(client).to have_received(:fail_job).
          with(123456, /UndeclaredOutput.*:unexpected/, retries: nil, backoff: nil)
      end
    end

    context "with manual complete! output validation" do
      before do
        allow(client).to receive(:complete_job)
        allow(client).to receive(:fail_job)
      end

      it "validates undeclared outputs on manual complete!" do
        worker = stub_const("ManualUndeclaredWorker", Class.new(described_class) do
          complete_job_on_success false
          output :status
          define_method(:perform) do
            complete!(status: "ok", extra: "surprise")
          end
        end)

        expect { worker.perform_job(job) }.not_to raise_error
        expect(client).not_to have_received(:complete_job)
        expect(client).to have_received(:fail_job).
          with(123456, /UndeclaredOutput.*:extra/, retries: nil, backoff: nil)
      end

      it "validates required outputs on manual complete!" do
        worker = stub_const("ManualMissingWorker", Class.new(described_class) do
          complete_job_on_success false
          output :notification_id, required: true
          define_method(:perform) do
            complete!({})
          end
        end)

        expect { worker.perform_job(job) }.not_to raise_error
        expect(client).not_to have_received(:complete_job)
        expect(client).to have_received(:fail_job).
          with(123456, /MissingOutput.*:notification_id/, retries: nil, backoff: nil)
      end

      it "re-raises validation error when fail_job_on_error is false" do
        worker = stub_const("ManualNoFailWorker", Class.new(described_class) do
          complete_job_on_success false
          fail_job_on_error false
          output :status, required: false
          define_method(:perform) do
            complete!(extra: "surprise")
          end
        end)

        logger = instance_double(Logger, warn: nil)
        allow(Busybee).to receive(:logger).and_return(logger)

        expect { worker.perform_job(job) }.not_to raise_error
        expect(client).not_to have_received(:complete_job)
        expect(client).not_to have_received(:fail_job)
        expect(logger).to have_received(:warn).with(/fail_job_on_error is off.*UndeclaredOutput/)
      end

      it "passes through when outputs are valid" do
        worker = stub_const("ManualValidWorker", Class.new(described_class) do
          complete_job_on_success false
          output :status
          define_method(:perform) do
            complete!(status: "ok")
          end
        end)

        worker.perform_job(job)
        expect(client).to have_received(:complete_job).with(123456, vars: { status: "ok" })
      end

      it "skips strict validation when strict_outputs is false" do
        worker = stub_const("ManualLenientWorker", Class.new(described_class) do
          complete_job_on_success false
          strict_outputs false
          output :status
          define_method(:perform) do
            complete!(status: "ok", extra: "allowed")
          end
        end)

        worker.perform_job(job)
        expect(client).to have_received(:complete_job).with(123456, vars: { status: "ok", extra: "allowed" })
      end
    end
  end

  describe Busybee::Worker::Shutdown do
    def raise_with_cause(cause_class, cause_message, **shutdown_kwargs)
      raise cause_class, cause_message
    rescue cause_class
      raise described_class.new(**shutdown_kwargs)
    end

    it "builds a message from worker class and cause" do
      error = raise_with_cause(RuntimeError, "connection lost", worker: String) rescue $! # rubocop:disable Style/RescueModifier

      expect(error.message).to include("Shutting down worker")
      expect(error.message).to include("RuntimeError")
      expect(error.message).to include("String")
      expect(error.message).to include("connection lost")
      expect(error.worker_class).to eq(String)
      expect(error.cause).to be_a(RuntimeError)
    end

    it "handles missing cause gracefully" do
      error = described_class.new(worker: String)
      expect(error.message).to include("due to error")
      expect(error.message).to include("String")
    end

    it "handles anonymous worker class" do
      error = described_class.new(worker: Class.new)
      expect(error.message).not_to include(" in ")
    end

    it "accepts a custom base message" do
      error = described_class.new("Custom shutdown reason", worker: String)
      expect(error.message).to start_with("Custom shutdown reason")
    end
  end

  describe "#perform" do
    it "raises NotImplementedError by default" do
      instance = minimal_worker.new(job)
      expect { instance.perform }.to raise_error(NotImplementedError, /perform/)
    end

    it "can be overridden in subclasses" do
      instance = performing_worker.new(job)
      expect(instance.perform).to eq(processed: true)
    end
  end

  describe "#job" do
    it "exposes the job passed to the constructor" do
      instance = minimal_worker.new(job)
      expect(instance.job).to be(job)
    end
  end

  describe "delegations to job" do
    let(:instance) { performing_worker.new(job) }

    describe "#client" do
      it "delegates to job" do
        expect(instance.client).to be(client)
      end
    end

    describe "#variables" do
      it "delegates to job" do
        expect(instance.variables).to eq(job.variables)
      end
    end

    describe "#headers" do
      it "delegates to job" do
        expect(instance.headers).to eq(job.headers)
      end
    end

    describe "#complete!" do
      it "validates outputs then delegates to job" do
        allow(client).to receive(:complete_job)
        instance.complete!(result: "done")
        expect(client).to have_received(:complete_job).with(123456, vars: { result: "done" })
      end
    end

    describe "#fail!" do
      it "delegates to job" do
        allow(client).to receive(:fail_job)
        instance.fail!("Something broke", retries: 2)
        expect(client).to have_received(:fail_job).with(123456, "Something broke", retries: 2, backoff: nil)
      end
    end

    describe "#throw_bpmn_error!" do
      it "delegates to job" do
        allow(client).to receive(:throw_bpmn_error)
        instance.throw_bpmn_error!(:order_not_found, "Order missing")
        expect(client).to have_received(:throw_bpmn_error).with(123456, "ORDER_NOT_FOUND", message: "Order missing")
      end
    end

    describe "#update_retries" do
      it "delegates to job" do
        allow(client).to receive(:update_job_retries)
        instance.update_retries(5)
        expect(client).to have_received(:update_job_retries).with(123456, 5)
      end
    end

    describe "#update_timeout" do
      it "delegates to job" do
        allow(client).to receive(:update_job_timeout)
        instance.update_timeout(30_000)
        expect(client).to have_received(:update_job_timeout).with(123456, 30_000)
      end
    end
  end
end
