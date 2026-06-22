# frozen_string_literal: true

require "busybee/client/call"

RSpec.describe Busybee::Client::Call do
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
      expect(call.error_class).to eq("RuntimeError")
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

  describe "context bag" do
    it "seeds from the ambient hook context at construction, as an HWIA" do
      Busybee::Hooks.with_context(job_key: 42) do
        call = described_class.new(:complete_job)
        expect(call.context[:job_key]).to eq(42)
        expect(call.context["job_key"]).to eq(42)
      end
    end

    it "snapshots the ambient context, decoupled from later restoration" do
      call = nil
      Busybee::Hooks.with_context(job_key: 42) { call = described_class.new(:complete_job) }
      expect(call.context[:job_key]).to eq(42)
    end

    it "lets a hook annotate a new key" do
      call = described_class.new(:complete_job)
      call.set_context(trace_id: "abc")
      expect(call.context[:trace_id]).to eq("abc")
    end

    it "is set-once: neither seeded nor previously-annotated keys can be clobbered" do
      Busybee::Hooks.with_context(job_key: 42) do
        call = described_class.new(:complete_job)
        call.set_context(job_key: 99, trace_id: "abc")
        call.set_context(trace_id: "xyz")
        expect(call.context[:job_key]).to eq(42)
        expect(call.context[:trace_id]).to eq("abc")
      end
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

    it "is a superset in logging_context, adding attempts and durations" do
      call = described_class.new(:complete_job)
      call._begin_attempt
      call._resolve(status: :succeeded)
      log = call.logging_context
      expect(log).to include(rpc: :complete_job, status: :succeeded, attempts: 1)
      expect(log).to have_key(:total_ms)
    end

    it "merges context-value contributions via the duck protocol, the call's own keys winning" do
      contributor = Struct.new(:context_tags).new({ rpc: :should_lose, region: "us-east" })

      Busybee::Hooks.with_context(thing: contributor) do
        call = described_class.new(:complete_job)
        tags = call.context_tags
        expect(tags[:region]).to eq("us-east")
        expect(tags[:rpc]).to eq(:complete_job)
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
  end
end
