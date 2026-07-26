# frozen_string_literal: true

require "busybee/client/call"

RSpec.describe Busybee::Client::Call do
  it_behaves_like "a two-cardinality projection" do
    let(:projectable) do
      described_class.new(:complete_job).tap do |call|
        call._begin_attempt
        call._record_result(:ok)
        call._resolve(status: :succeeded)
      end
    end
  end

  describe "construction" do
    it "carries the rpc and starts pending with no attempts" do
      call = described_class.new(:complete_job)

      aggregate_failures do
        expect(call.rpc).to eq(:complete_job)
        expect(call.status).to eq(:pending)
        expect(call.pending?).to be(true)
        expect(call.succeeded?).to be(false)
        expect(call.errored?).to be(false)
        expect(call.resolved?).to be(false)
        expect(call.attempts).to eq(0)
      end
    end

    it "defaults the request to nil" do
      expect(described_class.new(:complete_job).request).to be_nil
    end

    it "carries the request when given" do
      req = double("Request") # rubocop:disable RSpec/VerifiedDoubles
      expect(described_class.new(:complete_job, req).request).to be(req)
    end
  end

  describe "#_begin_attempt" do
    it "counts each initiated attempt" do
      call = described_class.new(:complete_job)
      call._begin_attempt
      call._begin_attempt
      expect(call.attempts).to eq(2)
    end
  end

  describe "#_record_result / #_record_error" do
    it "records a success result" do
      call = described_class.new(:complete_job)
      call._record_result("ok")
      expect(call.result).to eq("ok")
      expect(call.error).to be_nil
    end

    it "records an error" do
      call = described_class.new(:complete_job)
      boom = RuntimeError.new("boom")
      call._record_error(boom)
      expect(call.error).to be(boom)
      expect(call.result).to be_nil
    end

    it "is mutually exclusive, latest wins: an error after a result clears the result" do
      call = described_class.new(:complete_job)
      call._record_result("ok")
      call._record_error(RuntimeError.new("boom"))
      expect(call.result).to be_nil
      expect(call.error).to be_a(RuntimeError)
    end

    it "is mutually exclusive, latest wins: a result after an error clears the error (retry succeeds)" do
      call = described_class.new(:complete_job)
      call._record_error(RuntimeError.new("boom"))
      call._record_result("ok")
      expect(call.error).to be_nil
      expect(call.result).to eq("ok")
    end
  end

  describe "#_resolve" do
    it "transitions to succeeded" do
      call = described_class.new(:complete_job)
      call._resolve(status: :succeeded)
      expect(call.status).to eq(:succeeded)
      expect(call.succeeded?).to be(true)
      expect(call.resolved?).to be(true)
    end

    it "transitions to errored" do
      call = described_class.new(:complete_job)
      call._resolve(status: :errored)
      expect(call.errored?).to be(true)
      expect(call.resolved?).to be(true)
    end
  end

  describe "#error_class / #error_message" do
    it "derives both from the recorded error" do
      call = described_class.new(:complete_job)
      call._record_error(RuntimeError.new("boom"))
      expect(call.error_class).to eq(RuntimeError) # the Class, matching worker_class
      expect(call.error_message).to eq("boom")
    end

    it "are nil with no recorded error" do
      call = described_class.new(:complete_job)
      expect(call.error_class).to be_nil
      expect(call.error_message).to be_nil
    end
  end

  describe "#grpc_status" do
    it "is :ok when succeeded" do
      call = described_class.new(:complete_job)
      call._resolve(status: :succeeded)
      expect(call.grpc_status).to eq(:ok)
    end

    it "reflects the recorded GRPC error's status even while still pending (mid-retry)" do
      call = described_class.new(:complete_job)
      call._record_error(Busybee::GRPC::Error.wrap(GRPC::ResourceExhausted.new("backpressure")))
      expect(call.pending?).to be(true)
      expect(call.grpc_status).to eq(:resource_exhausted)
    end

    it "is nil when the recorded error is not a Busybee::GRPC::Error" do
      call = described_class.new(:complete_job)
      call._record_error(RuntimeError.new("boom"))
      call._resolve(status: :errored)
      expect(call.grpc_status).to be_nil
    end

    it "is nil while pending with no error" do
      call = described_class.new(:complete_job)
      expect(call.grpc_status).to be_nil
    end
  end

  # Timing logic lives in Call::Timestamps (see call/timestamps_spec); here we
  # just confirm the call delegates and that #attempt drives the network window.
  describe "timing (delegated to Timestamps)" do
    it "exposes created_at from construction" do
      expect(described_class.new(:complete_job).created_at).to be_a(Time)
    end

    it "computes total_ms once resolved" do
      call = described_class.new(:complete_job)
      expect(call.total_ms).to be_nil
      call._resolve(status: :succeeded)
      expect(call.total_ms).to be >= 0
    end

    it "records network timing across an attempt" do
      call = described_class.new(:complete_job)
      call.attempt { "ok" }
      expect(call.network_ms).to be >= 0
    end
  end

  describe "correlation carriers" do
    let(:worker_status) { instance_double(Busybee::Worker::Status) }
    let(:job) { instance_double(Busybee::Job, worker_status: worker_status) }

    it "captures the ambient worker_status at construction" do
      call = nil
      described_class.with_worker_status(worker_status) { call = described_class.new(:activate_jobs) }
      expect(call.worker_status).to be(worker_status)
    end

    it "captures the ambient job at construction" do
      call = nil
      described_class.with_job(job) { call = described_class.new(:complete_job) }
      expect(call.job).to be(job)
    end

    it "restores each carrier after its block, even when the block raises" do
      expect { described_class.with_worker_status(worker_status) { raise "boom" } }.to raise_error("boom")
      expect(described_class.current_worker_status).to be_nil
    end

    it "falls through to a present job's own worker_status (a separately-seeded one cannot override)" do
      job_status = instance_double(Busybee::Worker::Status)
      job_with_status = instance_double(Busybee::Job, worker_status: job_status)
      described_class.with_worker_status(worker_status) do
        described_class.with_job(job_with_status) do
          expect(described_class.current_worker_status).to be(job_status)
        end
      end
    end

    it "is thread-local — a spawned thread sees neither carrier" do
      seen = :unset
      described_class.with_job(job) { seen = Thread.new { described_class.current_job }.value }
      expect(seen).to be_nil
    end
  end

  describe "#context_tags / #logging_context" do
    it "exposes the call's own low-cardinality tags, omitting nils" do
      call = described_class.new(:complete_job)
      call._resolve(status: :succeeded)
      tags = call.context_tags
      expect(tags).to include(rpc: :complete_job, status: :succeeded, grpc_status: :ok)
      expect(tags).not_to have_key(:error_class)
    end

    it "renders error_class as its name string in tags/logging, not the Class object" do
      # error_class the reader returns the Class (label-unfriendly); the projection
      # coerces it to the name string so metric labels / log fields stay scalar.
      call = described_class.new(:complete_job)
      call._record_error(RuntimeError.new("boom"))
      call._resolve(status: :errored)
      expect(call.context_tags[:error_class]).to eq("RuntimeError")
      expect(call.logging_context[:error_class]).to eq("RuntimeError")
    end

    it "is a superset in logging_context, adding attempts and durations" do
      call = described_class.new(:complete_job)
      call._begin_attempt
      call._resolve(status: :succeeded)
      log = call.logging_context
      expect(log).to include(rpc: :complete_job, status: :succeeded, attempts: 1)
      expect(log).to have_key(:total_ms)
    end

    context "with correlation carriers seeded" do
      let(:worker_status) do
        instance_double(Busybee::Worker::Status,
                        worker_class: stub_const("CorrWorker", Class.new),
                        job_type: "process_order", worker_mode: :polling, worker_name: "host-7")
      end
      let(:job) do
        instance_double(Busybee::Job, worker_status: worker_status,
                                      bpmn_process_id: "order-flow", source: :poll,
                                      key: 123, process_instance_key: 456, element_id: "task-1")
      end

      def call_in_context
        captured = nil
        described_class.with_worker_status(worker_status) do
          described_class.with_job(job) { captured = described_class.new(:complete_job) }
        end
        captured
      end

      it "folds curated worker + job identity into context_tags, the call's own winning" do
        expect(call_in_context.context_tags).to include(
          worker_class: "CorrWorker", job_type: "process_order", worker_mode: :polling,
          bpmn_process_id: "order-flow", source: :poll,
          rpc: :complete_job, status: :pending
        )
      end

      it "keeps worker_name, gauges, job keys/timings, and retries out of the tags" do
        tags = call_in_context.context_tags
        aggregate_failures do
          expect(tags).not_to have_key(:worker_name) # per-run-unique → logging only
          expect(tags).not_to have_key(:retries) # engine budget; collides with attempts
          expect(tags).not_to have_key(:job_key)
          expect(tags).not_to have_key(:total_job_count)
        end
      end

      it "adds worker_name and job/instance keys in logging_context" do
        expect(call_in_context.logging_context).to include(
          worker_name: "host-7", job_key: 123, process_instance_key: 456, element_id: "task-1"
        )
      end
    end
  end

  describe "#attempt (per-attempt bracket)" do
    after { Busybee::Hooks.reset! }

    it "runs around_call around the gRPC attempt, observing" do
      events = []
      Busybee.around_call do |_call, proceed|
        events << :before
        proceed.call
        events << :after
      end

      described_class.new(:complete_job).attempt { events << :stub }
      expect(events).to eq(%i[before stub after])
    end

    it "records the result of a successful attempt and counts the attempt" do
      call = described_class.new(:complete_job)
      call.attempt { "result-value" }
      aggregate_failures do
        expect(call.result).to eq("result-value")
        expect(call.error).to be_nil
        expect(call.attempts).to eq(1)
      end
    end

    it "records and re-raises a raw GRPC error, translated to Busybee::GRPC::Error" do
      call = described_class.new(:complete_job)
      expect { call.attempt { raise GRPC::Unavailable, "down" } }.to raise_error(Busybee::GRPC::Error)
      aggregate_failures do
        expect(call.error).to be_a(Busybee::GRPC::Error)
        expect(call.grpc_status).to eq(:unavailable)
      end
    end

    it "closes the network bracket before recording the error (network_ms excludes translation)" do
      call = described_class.new(:complete_job)
      allow(call).to receive(:translate_error).and_wrap_original do |original, e|
        sleep 0.1 # slow error translation/recording, after the gRPC op already returned
        original.call(e)
      end

      expect { call.attempt { raise GRPC::Unavailable, "down" } }.to raise_error(Busybee::GRPC::Error)
      expect(call.network_ms).to be < 50 # the 100ms delay is bookkeeping, outside the network window
    end

    it "records and re-raises a non-GRPC error as-is" do
      call = described_class.new(:complete_job)
      boom = RuntimeError.new("boom")
      expect { call.attempt { raise boom } }.to raise_error(boom)
      expect(call.error).to be(boom)
    end

    it "re-raises past the observing chain (the safe chain would otherwise swallow it)" do
      Busybee.around_call { |_call, proceed| proceed.call }
      call = described_class.new(:complete_job)
      expect { call.attempt { raise GRPC::Unavailable, "x" } }.to raise_error(Busybee::GRPC::Error)
    end

    it "swallows a raising around_call middleware and still runs the attempt" do
      ran = false
      Busybee.around_call { |_call, _proceed| raise "broken middleware" }
      described_class.new(:complete_job).attempt { ran = true }
      expect(ran).to be(true)
    end

    it "escalates a shutdown_on-declared middleware error to Shutdown instead of swallowing it" do
      original = Busybee.shutdown_on_errors
      begin
        Busybee.shutdown_on_errors = [RuntimeError]
        Busybee.around_call { |_call, _proceed| raise "db gone" }

        expect { described_class.new(:complete_job).attempt { "ok" } }.
          to raise_error(Busybee::Worker::Shutdown)
      ensure
        Busybee.shutdown_on_errors = original
      end
    end
  end

  describe ".with_hooks (logical bracket)" do
    after { Busybee::Hooks.reset! }

    it "fires before_call once at initiation and returns the result on success" do
      fired = []
      Busybee.before_call { |call| fired << call.rpc }

      result = described_class.with_hooks(:complete_job) { |call| call.attempt { "ok" } }
      aggregate_failures do
        expect(fired).to eq([:complete_job])
        expect(result).to eq("ok")
      end
    end

    it "resolves to succeeded and fires after_call (observing) on success" do
      statuses = []
      Busybee.after_call { |call| statuses << call.status }

      described_class.with_hooks(:complete_job) { |call| call.attempt { "ok" } }
      expect(statuses).to eq([:succeeded])
    end

    it "treats before_call as gating: a raising before_call aborts before yield, with no after_call" do
      yielded = false
      after_fired = false
      Busybee.before_call { raise "gate closed" }
      Busybee.after_call { after_fired = true }

      expect do
        described_class.with_hooks(:complete_job) { |_call| yielded = true }
      end.to raise_error("gate closed")
      aggregate_failures do
        expect(yielded).to be(false)
        expect(after_fired).to be(false)
      end
    end

    it "on error: resolves to errored, re-raises, and fires after_call once" do
      after_statuses = []
      Busybee.after_call { |call| after_statuses << call.status }

      expect do
        described_class.with_hooks(:complete_job) { |call| call.attempt { raise GRPC::Unavailable, "x" } }
      end.to raise_error(Busybee::GRPC::Error)
      expect(after_statuses).to eq([:errored])
    end

    it "treats after_call as observing: a raising after_call does not mask the result" do
      Busybee.after_call { raise "logging hook died" }

      result = described_class.with_hooks(:complete_job) { |call| call.attempt { "ok" } }
      expect(result).to eq("ok")
    end

    it "exposes the request to hooks" do
      seen = nil
      Busybee.before_call { |call| seen = call.request }
      req = double("Request") # rubocop:disable RSpec/VerifiedDoubles

      described_class.with_hooks(:complete_job, req) { |call| call.attempt { "ok" } }
      expect(seen).to be(req)
    end
  end
end
