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

  let(:performing_worker) do
    stub_const("PerformingWorker", Class.new(described_class) do
      strict_outputs false
      define_method(:perform) do
        { processed: true }
      end
    end)
  end
  let(:minimal_worker) do
    stub_const("MinimalWorker", Class.new(described_class))
  end

  describe "error policy invariance (perform lifecycle)" do
    before { allow(client).to receive(:fail_job) }

    after { Busybee::Hooks.reset! }

    # A fresh job per turn. Autofail reports every escaping error now, so a
    # shared job would arrive at the second turn already resolved and the two
    # turns would stop comparing the same path.
    def exercise(&work)
      Class.new(Busybee::Worker) do
        def self.name = "InvarianceWorker"
        job_type "invariance"
        define_method(:perform) { work.call }
      end.perform_job(Busybee::Job.new(raw_job, client: client))
    end

    def register_observer = Busybee.around_perform { |_job, perform| perform.call }

    def register_raising_observer = Busybee.around_perform { |_job, _perform| raise "hook boom" }

    it_behaves_like "a hook-count-invariant error policy"
  end

  describe ".perform_job" do
    before { allow(client).to receive(:complete_job) }

    it "calls perform on a new instance and returns the result hash" do
      expect(performing_worker.perform_job(job)).to eq("processed" => true)
    end

    it "raises NotImplementedError when perform is not overridden" do
      expect { minimal_worker.perform_job(job) }.to raise_error(NotImplementedError, /perform/)
    end

    it "leaves the job unresolved and still settleable when a non-StandardError escapes" do
      worker = stub_const("NonStdErrorWorker", Class.new(described_class) do
        strict_outputs false
        define_method(:perform) { raise Exception, "weird" } # rubocop:disable Lint/RaiseException
      end)

      expect { worker.perform_job(job) }.to raise_error(Exception, "weird")

      # A non-StandardError escapes perform_job without resolving the job, so
      # the engine never heard: it is still ours to settle afterwards.
      expect { job.complete!(processed: true) }.not_to raise_error
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

      it "captures the GRPC error on the Job when auto-complete fails" do
        allow(client).to receive(:complete_job).and_raise(GRPC::Unavailable, "connection lost")
        allow(Busybee).to receive(:logger).and_return(instance_double(Logger, warn: nil))

        performing_worker.perform_job(job)

        aggregate_failures do
          expect(job.ready?).to be true                  # status didn't advance — GRPC failed before resolve!
          expect(job.result).to eq("processed" => true)  # result axis set before GRPC failure
          expect(job.error).to be_a(GRPC::Unavailable)   # error axis captured for telemetry
        end
      end
    end

    context "with automatic failure" do
      before { allow(client).to receive(:fail_job) }

      it "auto-fails the job when perform raises" do
        worker = stub_const("FailingWorker", Class.new(described_class) do
          define_method(:perform) { raise "boom" }
        end)

        worker.perform_job(job)
        expect(client).to have_received(:fail_job).with(123456, /RuntimeError.*boom/, retries: 2, backoff: nil)
      end

      it "uses configured backoff" do
        worker = stub_const("BackoffWorker", Class.new(described_class) do
          fail_job_backoff 30_000
          define_method(:perform) { raise "boom" }
        end)

        worker.perform_job(job)
        expect(client).to have_received(:fail_job).with(123456, anything, retries: 2, backoff: 30_000)
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

      it "captures the perform exception to Resolution even when the auto-fail GRPC fails" do
        allow(client).to receive(:fail_job).and_raise(GRPC::Unavailable, "connection lost")
        allow(Busybee).to receive(:logger).and_return(instance_double(Logger, warn: nil))

        worker = stub_const("CaptureWithFailingGrpcWorker", Class.new(described_class) do
          define_method(:perform) { raise "boom" }
        end)

        worker.perform_job(job)

        expect(job.error).to be_a(RuntimeError)
        expect(job.error.message).to eq("boom")
        expect(job).to be_ready
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
        expect(client).to have_received(:fail_job).with(123456, /PGConnectionBad.*gone/, retries: 2, backoff: nil)
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
          define_method(:perform) { raise Busybee::Worker::Shutdown.new(worker_class: self.class) }
        end)

        expect { worker.perform_job(job) }.to raise_error(Busybee::Worker::Shutdown)
      end

      it "auto-fails using the cause when Shutdown is raised directly" do
        worker = stub_const("DirectShutdownFailWorker", Class.new(described_class) do
          define_method(:perform) do
            raise "root cause"
          rescue StandardError
            raise Busybee::Worker::Shutdown.new(worker_class: self.class)
          end
        end)

        expect { worker.perform_job(job) }.to raise_error(Busybee::Worker::Shutdown)
        expect(client).to have_received(:fail_job).with(123456, /RuntimeError.*root cause/, retries: 2, backoff: nil)
      end

      it "captures the underlying cause (not the Shutdown wrapper) to Resolution" do
        worker = stub_const("ShutdownCaptureWorker", Class.new(described_class) do
          define_method(:perform) do
            raise "root cause"
          rescue StandardError
            raise Busybee::Worker::Shutdown.new(worker_class: self.class)
          end
        end)

        expect { worker.perform_job(job) }.to raise_error(Busybee::Worker::Shutdown)
        expect(job.error).to be_a(RuntimeError)
        expect(job.error.message).to eq("root cause")
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
          with(123456, /MissingInput.*:nonexistent/, retries: 2, backoff: nil)
      end

      it "lists all missing inputs" do
        worker = stub_const("MultiMissingWorker", Class.new(described_class) do
          variable :missing_one, required: true
          variable :missing_two, required: true
          define_method(:perform) { {} }
        end)

        expect { worker.perform_job(job) }.not_to raise_error
        expect(client).to have_received(:fail_job).with(123456, /missing_one.*missing_two/, retries: 2, backoff: nil)
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
        expect(client).to have_received(:fail_job).with(123456, /process-order worker/, retries: 2, backoff: nil)
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
          with(123456, /MissingOutput.*:notification_id/, retries: 2, backoff: nil)
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
          with(123456, /UndeclaredOutput.*:extra/, retries: 2, backoff: nil)
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
          with(123456, /UndeclaredOutput.*:unexpected/, retries: 2, backoff: nil)
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
          with(123456, /UndeclaredOutput.*:extra/, retries: 2, backoff: nil)
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
          with(123456, /MissingOutput.*:notification_id/, retries: 2, backoff: nil)
      end

      it "auto-fails instead of completing when a manual complete! passes an undeclared output" do
        worker = stub_const("ManualUndeclaredWorker", Class.new(described_class) do
          complete_job_on_success false
          output :status, required: false
          define_method(:perform) do
            complete!(extra: "surprise")
          end
        end)

        expect { worker.perform_job(job) }.not_to raise_error
        expect(client).not_to have_received(:complete_job)
        expect(client).to have_received(:fail_job).
          with(123456, /UndeclaredOutput.*:extra/, retries: 2, backoff: nil)
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

  describe "ambient job context (.perform_job)" do
    before { allow(client).to receive(:complete_job) }
    after { Busybee::Hooks.reset! }

    it "seeds the job so a Call built inside perform folds it" do
      captured_call = nil
      worker = stub_const("JobContextWorker", Class.new(described_class) do
        strict_outputs false
        define_method(:perform) do
          captured_call = Busybee::Client::Call.new(:complete_job)
          {}
        end
      end)
      worker.perform_job(job)
      expect(captured_call.job).to be(job)
    end

    it "seeds the job for part-of-perform hooks (a Call in after_perform folds it)" do
      captured_call = nil
      Busybee.after_perform { captured_call = Busybee::Client::Call.new(:complete_job) }
      performing_worker.perform_job(job)
      expect(captured_call.job).to be(job)
    end

    it "restores the previous thread-local carrier after perform_job" do
      performing_worker.perform_job(job)
      expect(Busybee::Client::Call.current_job).to be_nil
    end
  end

  describe Busybee::Worker::Shutdown do
    def raise_with_cause(cause_class, cause_message, **shutdown_kwargs)
      raise cause_class, cause_message
    rescue cause_class
      raise described_class.new(**shutdown_kwargs)
    end

    it "builds a message from worker class and cause" do
      error = raise_with_cause(RuntimeError, "connection lost", worker_class: String) rescue $! # rubocop:disable Style/RescueModifier

      expect(error.message).to include("Shutting down worker")
      expect(error.message).to include("RuntimeError")
      expect(error.message).to include("String")
      expect(error.message).to include("connection lost")
      expect(error.worker_class).to eq(String)
      expect(error.cause).to be_a(RuntimeError)
    end

    it "handles missing cause gracefully" do
      error = described_class.new(worker_class: String)
      expect(error.message).to include("due to error")
      expect(error.message).to include("String")
    end

    it "handles anonymous worker class" do
      error = described_class.new(worker_class: Class.new)
      expect(error.message).not_to include(" in ")
    end

    it "accepts a custom base message" do
      error = described_class.new("Custom shutdown reason", worker_class: String)
      expect(error.message).to start_with("Custom shutdown reason")
    end

    describe ".triggered_by?" do
      let(:fatal_worker) do
        stub_const("FatalRuntimeWorker", Class.new(Busybee::Worker) do
          shutdown_on RuntimeError
        end)
      end

      it "matches an error the worker class declared via shutdown_on" do
        expect(described_class.triggered_by?(RuntimeError.new("db gone"), fatal_worker)).to be true
        expect(described_class.triggered_by?(ArgumentError.new("nope"), fatal_worker)).to be false
      end

      it "matches an error declared in gem-level shutdown_on_errors" do
        original = Busybee.shutdown_on_errors
        begin
          Busybee.shutdown_on_errors = [IOError]
          expect(described_class.triggered_by?(IOError.new("pipe"), nil)).to be true
        ensure
          Busybee.shutdown_on_errors = original
        end
      end

      it "tolerates a nil or configuration-less worker class" do
        expect(described_class.triggered_by?(RuntimeError.new("x"), nil)).to be false
        expect(described_class.triggered_by?(RuntimeError.new("x"), Object)).to be false
      end
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

  describe "#worker_name" do
    it "returns the process-wide worker identity" do
      allow(Busybee).to receive(:worker_name).and_return("orders-pod-7")
      expect(minimal_worker.new(job).worker_name).to eq("orders-pod-7")
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

      # An instance built outside perform_job isn't attached to its job, so the
      # Job-side check finds no contract. This one has to stand on its own.
      it "validates against its own class when the job has no worker attached" do
        worker = stub_const("UnattachedWorker", Class.new(described_class) do
          output :status, required: false
        end)
        bare_job = Busybee::Job.new(raw_job, client: client)

        expect(bare_job.worker).to be_nil
        expect { worker.new(bare_job).complete!(surprise: "nope") }.
          to raise_error(Busybee::UndeclaredOutput, /:surprise/)
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

      it "stamps perform timestamps inside the around_perform chain (after middleware preamble)" do
        middleware_timestamp = nil
        Busybee.around_perform do |_job, perform|
          middleware_timestamp = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          perform.call
        end

        performing_worker.perform_job(job)
        expect(job.perform_started_at(:monotonic)).to be >= middleware_timestamp
      end
    end

    describe "before_perform hooks" do
      it "fires before perform with the Job in :ready status" do
        captured_status = nil
        Busybee.before_perform do |job|
          captured_status = job.status
        end

        performing_worker.perform_job(job)

        expect(captured_status).to eq(:ready)
      end

      it "passes the Job with its identity keys reachable" do
        received_job = nil
        Busybee.before_perform { |job| received_job = job }

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
        Busybee.before_perform { sequence << :hook }
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
        Busybee.before_perform { |job| received_worker = job.worker }

        performing_worker.perform_job(job)
        expect(received_worker).to be_a(performing_worker)
      end

      it "propagates errors to perform_job rescue (triggers autofail)" do
        Busybee.before_perform { raise "hook boom" }

        performing_worker.perform_job(job)
        expect(client).to have_received(:fail_job).with(123456, /hook boom/, retries: 2, backoff: nil)
      end

      it "lets a before_perform hook short-circuit the job, skipping perform" do
        sequence = []
        worker = stub_const("ShortCircuitWorker", Class.new(Busybee::Worker) do
          strict_outputs false
          define_method(:perform) { sequence << :perform }
        end)
        Busybee.before_perform do |job|
          sequence << :hook
          job.complete!({ early: true })
        end

        worker.perform_job(job)

        expect(sequence).to eq([:hook])
        expect(client).to have_received(:complete_job).with(123456, vars: { "early" => true }).once
      end

      it "reports the skipped perform at :info" do
        logger = instance_double(Logger, info: nil)
        allow(Busybee).to receive(:logger).and_return(logger)
        Busybee.before_perform { |job| job.complete!({ early: true }) }

        performing_worker.perform_job(job)

        expect(logger).to have_received(:info).with(/resolved by a hook before perform ran/)
      end

      it "does not report a skipped perform when perform actually ran" do
        logger = instance_double(Logger, info: nil)
        allow(Busybee).to receive(:logger).and_return(logger)

        performing_worker.perform_job(job)

        expect(logger).not_to have_received(:info)
      end

      it "clears flag on rescue entry so autofail works after hook error" do
        Busybee.before_perform { raise "hook boom" }

        performing_worker.perform_job(job)
        expect(job).to be_failed
      end

      it "triggers Shutdown when hook raises a shutdown_on error" do
        worker = stub_const("ShutdownHookWorker", Class.new(Busybee::Worker) do
          shutdown_on RuntimeError
          strict_outputs false
          define_method(:perform) { { done: true } }
        end)
        Busybee.before_perform { raise "db gone" }

        expect { worker.perform_job(job) }.to raise_error(Busybee::Worker::Shutdown)
      end

      it "respects prefiltering" do
        results = []
        Busybee.before_perform(worker_class: /Nonexistent/) { results << :filtered }
        Busybee.before_perform { results << :unfiltered }

        performing_worker.perform_job(job)
        expect(results).to eq([:unfiltered])
      end
    end

    describe "around_perform hooks" do
      it "wraps perform (before/core/after ordering)" do
        sequence = []
        Busybee.around_perform do |_job, perform|
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
        Busybee.around_perform do |job, perform|
          perform.call
          captured_result = job.result
        end

        performing_worker.perform_job(job)
        expect(captured_result).to eq("processed" => true)
      end

      it "does not overwrite result when perform calls complete! manually" do
        captured_result = nil
        Busybee.around_perform do |job, perform|
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
        Busybee.around_perform do |_job, perform|
          perform.call
          "forgot to return result"
        end

        performing_worker.perform_job(job)
        expect(client).to have_received(:complete_job).with(123456, vars: { "processed" => true })
      end

      it "lets an around_perform hook short-circuit before yielding, skipping perform" do
        sequence = []
        worker = stub_const("PrematureCompleteWorker", Class.new(Busybee::Worker) do
          strict_outputs false
          define_method(:perform) { sequence << :perform }
        end)
        Busybee.around_perform do |job, perform|
          job.complete!({ early: true })
          perform.call # forced continuation would run it anyway; the gate is what skips the work
        end

        worker.perform_job(job)

        expect(sequence).to be_empty
        expect(client).to have_received(:complete_job).with(123456, vars: { "early" => true }).once
      end

      it "lets an around_perform hook resolve after yielding, and stands down from auto-complete" do
        worker = stub_const("LateCompleteWorker", Class.new(Busybee::Worker) do
          strict_outputs false
          define_method(:perform) { { done: true } }
        end)
        Busybee.around_perform do |job, perform|
          perform.call
          job.complete!({ late: true })
        end

        worker.perform_job(job)

        expect(job).to be_completed
        # Set-once on the result axis: the chain's core already captured what
        # perform returned, so the late complete! transmits that rather than its
        # own vars — and handle_success then finds the job resolved and declines
        # to complete it a second time.
        expect(client).to have_received(:complete_job).with(123456, vars: { "done" => true }).once
      end

      it "warns that a late complete!'s variables were discarded" do
        logger = instance_double(Logger, warn: nil)
        allow(Busybee).to receive(:logger).and_return(logger)
        worker = stub_const("DiscardedVarsWorker", Class.new(Busybee::Worker) do
          strict_outputs false
          define_method(:perform) { { done: true } }
        end)
        Busybee.around_perform do |job, perform|
          perform.call
          job.complete!({ late: true })
        end

        worker.perform_job(job)

        expect(logger).to have_received(:warn).with(/discarded/)
      end

      # The sanctioned shape: resolve, then yield anyway. The gate skips the
      # work, so there is nothing to discard and nothing to warn about.
      it "does not warn when a hook's complete! is the one that sets the result" do
        logger = instance_double(Logger, warn: nil, info: nil)
        allow(Busybee).to receive(:logger).and_return(logger)
        Busybee.around_perform do |job, perform|
          job.complete!({ early: true })
          perform.call
        end

        performing_worker.perform_job(job)

        expect(logger).not_to have_received(:warn)
      end

      it "does not overwrite a hook's result when the skipped core returns nil" do
        worker = stub_const("SkippedCoreResultWorker", Class.new(Busybee::Worker) do
          strict_outputs false
          define_method(:perform) { { unreached: true } }
        end)
        Busybee.around_perform { |job, _perform| job.complete!({ early: true }) }

        worker.perform_job(job)

        expect(job.result).to eq("early" => true)
      end

      it "allows status changes inside perform" do
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

    describe "after_perform hooks" do
      it "fires after auto-complete with status :complete" do
        received_job = nil
        Busybee.after_perform { |job| received_job = job }

        performing_worker.perform_job(job)

        expect(received_job.status).to eq(:complete)
        expect(received_job).to be_completed
      end

      it "fires after manual complete inside perform" do
        received_job = nil
        Busybee.after_perform { |job| received_job = job }
        worker = stub_const("ManualAfterWorker", Class.new(Busybee::Worker) do
          strict_outputs false
          define_method(:perform) { complete!({ manual: true }) }
        end)

        worker.perform_job(job)
        expect(received_job.status).to eq(:complete)
      end

      # Resolving from here is legal (see the :ready case below); resolving
      # something already settled is not, and the error says so.
      it "reports an attempt to resolve an already-settled job as JobAlreadyHandled" do
        raised = nil
        Busybee.after_perform do |job|
          job.complete!({ late: true })
        rescue StandardError => e
          raised = e
        end

        performing_worker.perform_job(job)

        expect(raised).to be_a(Busybee::JobAlreadyHandled)
      end

      it "does not fire for a job a hook short-circuited, since perform was never attempted" do
        fired = false
        Busybee.before_perform { |job| job.complete!({ early: true }) }
        Busybee.after_perform { fired = true }

        performing_worker.perform_job(job)

        expect(fired).to be(false)
      end

      it "does not fire for a job that failed input validation" do
        fired = false
        worker = stub_const("RequiredInputWorker", Class.new(Busybee::Worker) do
          input :missing_thing, source: :variable, required: true
          define_method(:perform) { { done: true } }
        end)
        Busybee.after_perform { fired = true }

        worker.perform_job(job)

        expect(job).to be_failed
        expect(fired).to be(false)
      end

      it "receives the same Job as before_perform (it's the same Job object)" do
        before_perform_arg = nil
        after_perform_arg = nil
        Busybee.before_perform { |j| before_perform_arg = j }
        Busybee.after_perform { |j| after_perform_arg = j }

        performing_worker.perform_job(job)
        expect(after_perform_arg).to be(before_perform_arg)
      end

      it "includes result from complete! vars" do
        received_result = nil
        Busybee.after_perform { |job| received_result = job.result }

        performing_worker.perform_job(job)
        expect(received_result).to eq("processed" => true)
      end

      it "exposes timestamps on the Job" do
        received_job = nil
        Busybee.after_perform { |job| received_job = job }

        performing_worker.perform_job(job)
        expect(received_job.execution_started_at(:monotonic)).to be_a(Float)
        expect(received_job.resolved_at(:monotonic)).to be_a(Float)
      end

      it "fires after auto-fail with status :failed and error" do
        received_job = nil
        Busybee.after_perform { |job| received_job = job }
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
        Busybee.after_perform { |job| received_job = job }
        worker = stub_const("StringFailWorker", Class.new(Busybee::Worker) do
          define_method(:perform) { fail!("custom message") }
        end)

        worker.perform_job(job)

        expect(received_job.status).to eq(:failed)
        expect(received_job.error_message).to eq("custom message")
      end

      it "propagates shutdown_on errors from after_perform hooks" do
        worker = stub_const("ShutdownAfterWorker", Class.new(Busybee::Worker) do
          shutdown_on RuntimeError
          strict_outputs false
          define_method(:perform) { { done: true } }
        end)
        Busybee.after_perform { raise "db gone" }

        expect { worker.perform_job(job) }.to raise_error(Busybee::Worker::Shutdown)
      end

      it "prefilters by status — after_perform(status: :failed) skips completed jobs" do
        results = []
        Busybee.after_perform(status: :failed) { results << :failed_only }
        Busybee.after_perform { results << :all }

        performing_worker.perform_job(job)
        expect(results).to eq([:all])
      end

      it "prefilters by status — after_perform(status: :failed) fires for failed jobs" do
        results = []
        Busybee.after_perform(status: :failed) { results << :failed_only }
        worker = stub_const("PrefilterFailWorker", Class.new(Busybee::Worker) do
          define_method(:perform) { raise "boom" }
        end)

        worker.perform_job(job)
        expect(results).to eq([:failed_only])
      end

      it "fires after throw_bpmn_error! with error code" do
        received_job = nil
        Busybee.after_perform { |job| received_job = job }
        worker = stub_const("BpmnAfterWorker", Class.new(Busybee::Worker) do
          define_method(:perform) { throw_bpmn_error!(:not_found, "missing") }
        end)

        worker.perform_job(job)

        expect(received_job.status).to eq(:error)
        expect(received_job).to be_errored
        expect(received_job.error_code).to eq("NOT_FOUND")
        expect(received_job.error_message).to eq("missing")
      end

      # The four :ready shapes — perform ran, the engine was never told.
      it "fires when autofail's own GRPC call failed, with the job still :ready" do
        allow(Busybee).to receive(:logger).and_return(instance_double(Logger, warn: nil))
        allow(client).to receive(:fail_job).and_raise(GRPC::Unavailable, "connection lost")
        received = []
        Busybee.after_perform { |j| received << j }
        worker = stub_const("AfterFailingGrpcWorker", Class.new(Busybee::Worker) do
          define_method(:perform) { raise "boom" }
        end)

        worker.perform_job(job)

        expect(received.size).to eq(1)
        expect(job).to be_ready
        expect(job.error).to be_a(RuntimeError)
      end

      it "fires when auto-complete's own GRPC call failed" do
        allow(Busybee).to receive(:logger).and_return(instance_double(Logger, warn: nil))
        allow(client).to receive(:complete_job).and_raise(GRPC::Unavailable, "connection lost")
        received = []
        Busybee.after_perform { |j| received << j.status }

        performing_worker.perform_job(job)

        expect(received).to eq([:ready])
        expect(job.error).to be_a(GRPC::Unavailable)
      end

      it "fires when perform hands resolution to something else" do
        received = []
        Busybee.after_perform { |j| received << j.status }
        worker = stub_const("DeferredResolutionWorker", Class.new(Busybee::Worker) do
          complete_job_on_success false
          define_method(:perform) { :handed_off }
        end)

        worker.perform_job(job)

        expect(received).to eq([:ready])
      end

      it "autofails the job when a hook raises while it is still :ready" do
        Busybee.after_perform { raise "hook boom" }
        worker = stub_const("ReadyHookRaiser", Class.new(Busybee::Worker) do
          complete_job_on_success false
          define_method(:perform) { :handed_off }
        end)

        expect { worker.perform_job(job) }.not_to raise_error

        expect(job.status).to eq(:failed)
        expect(client).to have_received(:fail_job).with(123456, /RuntimeError.*hook boom/, retries: 2, backoff: nil)
      end

      it "reports a hook's error against an already-settled job without re-resolving it" do
        logger = instance_double(Logger, warn: nil, error: nil)
        allow(Busybee).to receive(:logger).and_return(logger)
        Busybee.after_perform { raise "hook boom" }

        expect { performing_worker.perform_job(job) }.not_to raise_error

        expect(job.status).to eq(:complete)
        expect(client).not_to have_received(:fail_job)
        expect(logger).to have_received(:warn).with(/already complete: \[RuntimeError\] hook boom/)
      end

      # An escalation on its way out is not a second error arriving late.
      it "does not re-report a Shutdown that passed the hooks on its way out" do
        logger = instance_double(Logger, warn: nil)
        allow(Busybee).to receive(:logger).and_return(logger)
        stub_const("FatalPerformError", Class.new(StandardError))
        Busybee.after_perform { |_j| nil }
        worker = stub_const("EscalatingPerformWorker", Class.new(Busybee::Worker) do
          shutdown_on FatalPerformError
          define_method(:perform) { raise FatalPerformError, "db gone" }
        end)

        expect { worker.perform_job(job) }.to raise_error(Busybee::Worker::Shutdown)

        expect(logger).not_to have_received(:warn).with(/after job was already/)
      end

      it "escalates a shutdown_on error raised by a hook" do
        stub_const("FatalHookError", Class.new(StandardError))
        Busybee.after_perform { raise FatalHookError, "db gone" }
        worker = stub_const("ShutdownHookWorker", Class.new(Busybee::Worker) do
          strict_outputs false
          shutdown_on FatalHookError
          define_method(:perform) { { done: true } }
        end)

        expect { worker.perform_job(job) }.to raise_error(Busybee::Worker::Shutdown)
      end

      it "autofails an invalid output offered by a hook, however the hook spells the call" do
        Busybee.after_perform { |j| j.complete!(surprise: "nope") if j.ready? }
        worker = stub_const("HookUndeclaredWorker", Class.new(Busybee::Worker) do
          complete_job_on_success false
          output :status, required: false
          define_method(:perform) { :handed_off }
        end)

        worker.perform_job(job)

        expect(client).not_to have_received(:complete_job)
        expect(client).to have_received(:fail_job).with(123456, /UndeclaredOutput.*:surprise/, retries: 2, backoff: nil)
      end

      # Why reaching them matters: the job is still the worker's to settle.
      it "can settle a job it finds still :ready" do
        Busybee.after_perform { |j| j.fail!("nobody else claimed it") if j.ready? }
        worker = stub_const("HandOffWorker", Class.new(Busybee::Worker) do
          complete_job_on_success false
          define_method(:perform) { :handed_off }
        end)

        worker.perform_job(job)

        expect(job.status).to eq(:failed)
        expect(client).to have_received(:fail_job).with(123456, "nobody else claimed it", retries: 2, backoff: nil)
      end

      it "fires on the way out when a non-StandardError escapes perform" do
        received = []
        Busybee.after_perform { |j| received << j.status }
        worker = stub_const("AfterNonStdErrorWorker", Class.new(Busybee::Worker) do
          define_method(:perform) { raise Exception, "weird" } # rubocop:disable Lint/RaiseException
        end)

        expect { worker.perform_job(job) }.to raise_error(Exception, "weird")

        expect(received).to eq([:ready])
      end

      it "sees both result and error in Variant D (manual fail then return a partial-payload hash)" do
        received_job = nil
        Busybee.after_perform { |j| received_job = j }
        worker = stub_const("FailThenReturnWorker", Class.new(Busybee::Worker) do
          strict_outputs false
          define_method(:perform) do
            fail!("validation failed")
            { partial: true, attempted_at: "2026-06-08" }
          end
        end)

        worker.perform_job(job)

        expect(received_job).to be_failed
        expect(received_job.error_message).to eq("validation failed")
        expect(received_job.result).to eq("partial" => true, "attempted_at" => "2026-06-08")
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
          with(%r{already complete: \[RuntimeError\] post-complete error \(at .+/worker_spec\.rb:\d+})
      end

      # The operator's next move depends on this sentence. A job the engine has
      # already been told about is not coming back, and saying otherwise sends
      # them looking for a redelivery that will never arrive.
      it "never says a job that resolved before the raise will time out and retry" do
        logger = instance_double(Logger, warn: nil)
        allow(Busybee).to receive(:logger).and_return(logger)
        worker = stub_const("ResolvedThenRaisingWorker", Class.new(Busybee::Worker) do
          strict_outputs false
          define_method(:perform) do
            complete!({ done: true })
            raise "post-complete error"
          end
        end)

        worker.perform_job(job)

        expect(job.status).to eq(:complete)
        expect(logger).not_to have_received(:warn).with(/timeout and retry/)
      end
    end

    describe "around_perform hooks (continued)" do
      it "fires before_perform before around_perform" do
        sequence = []
        Busybee.before_perform { sequence << :before }
        Busybee.around_perform do |_job, perform|
          sequence << :around
          perform.call
        end

        performing_worker.perform_job(job)
        expect(sequence).to eq(%i[before around])
      end
    end
  end
end
