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

  # The monotonic clock can't be controlled, so these assert ordering/sign and
  # nil-until-stamped semantics rather than exact durations.
  describe "timing and durations" do
    it "stamps created_at at construction" do
      expect(described_class.new(:complete_job).created_at).to be_a(Time)
    end

    it "leaves resolved_at and total_ms nil until resolved" do
      call = described_class.new(:complete_job)
      expect(call.resolved_at).to be_nil
      expect(call.total_ms).to be_nil
    end

    it "stamps resolved_at and computes a non-negative total_ms on resolve" do
      call = described_class.new(:complete_job)
      call._resolve(status: :succeeded)
      expect(call.resolved_at).to be_a(Time)
      expect(call.total_ms).to be >= 0
    end

    it "computes a non-negative network_ms across an attempt's network bracket" do
      call = described_class.new(:complete_job)
      call._begin_attempt
      call._begin_network
      call._end_network
      expect(call.network_ms).to be >= 0
    end

    it "leaves queue_ms nil before the first attempt starts" do
      expect(described_class.new(:complete_job).queue_ms).to be_nil
    end

    it "computes a non-negative queue_ms from created to first attempt start" do
      call = described_class.new(:complete_job)
      call._begin_attempt
      call._begin_network
      expect(call.queue_ms).to be >= 0
    end

    it "has nil backoff_ms on the first attempt" do
      call = described_class.new(:complete_job)
      call._begin_attempt
      call._begin_network
      call._end_network
      expect(call.backoff_ms).to be_nil
    end

    it "computes a non-negative backoff_ms on a retry, readable post-yield" do
      call = described_class.new(:complete_job)
      call._begin_attempt
      call._begin_network
      call._end_network                  # attempt 1 finished
      call._begin_attempt
      call._begin_network                # attempt 2 started
      call._end_network                  # post-yield: prior finish still the backoff basis
      expect(call.backoff_ms).to be >= 0
    end

    it "accumulates network time across attempts" do
      call = described_class.new(:complete_job)
      call._begin_attempt
      call._begin_network
      call._end_network
      first = call.cumulative_network_ms
      call._begin_attempt
      call._begin_network
      call._end_network
      expect(call.cumulative_network_ms).to be >= first
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
end
