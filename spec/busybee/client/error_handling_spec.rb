# frozen_string_literal: true

require "active_support/core_ext/numeric/time"

require "busybee/client/error_handling"

RSpec.describe Busybee::Client::ErrorHandling do
  let(:test_class) do
    Class.new { include Busybee::Client::ErrorHandling }
  end
  let(:instance) { test_class.new }

  # with_retry is retry-only: it expects its block to raise an already-translated
  # Busybee::GRPC::Error (the Call#attempt seam translates per attempt) and
  # decides retryability from the wrapped cause.
  def wrapped(raw)
    Busybee::GRPC::Error.wrap(raw)
  end

  describe "#with_retry" do
    it "returns the block's value on success" do
      expect(instance.with_retry { "ok" }).to eq("ok")
    end

    context "when retry is disabled" do
      before { Busybee.grpc_retry_enabled = false }
      after { Busybee.grpc_retry_enabled = nil }

      it "does not retry, even a retryable error" do
        call_count = 0
        expect do
          instance.with_retry do
            call_count += 1
            raise wrapped(GRPC::Unavailable.new("connection refused"))
          end
        end.to raise_error(Busybee::GRPC::Error)
        expect(call_count).to eq(1)
      end
    end

    context "when retry is enabled" do
      before do
        Busybee.grpc_retry_enabled = true
        Busybee.grpc_retry_delay = 0 # Retry immediately; the delay has its own examples below
      end

      after do
        Busybee.grpc_retry_enabled = nil
        Busybee.grpc_retry_delay = nil
      end

      # Both spellings of one delay have to reach sleep as the same number of
      # seconds. Nothing asserted the sleep at all before — the examples around
      # this one just set the delay small enough not to notice.
      {
        "integer milliseconds" => [500, 0.5],
        "a whole-second Duration" => [2.seconds, 2.0],
        "a sub-second Duration" => [0.5.seconds, 0.5]
      }.each do |shape, (configured, expected_seconds)|
        it "waits #{expected_seconds}s between attempts when configured with #{shape}" do
          Busybee.grpc_retry_delay = configured
          allow(instance).to receive(:sleep)

          call_count = 0
          instance.with_retry do
            call_count += 1
            raise wrapped(GRPC::Unavailable.new("temporary")) if call_count == 1

            "success"
          end

          expect(instance).to have_received(:sleep).with(expected_seconds)
        end
      end

      # The examples above stub sleep to read its argument. This one lets it run,
      # because "converts the value" and "actually waits that long" are different
      # claims and the second is the one an operator feels. Kept small because a
      # regression sleeps this number as seconds, uninterruptibly.
      it "really waits, at the magnitude configured" do
        Busybee.grpc_retry_delay = 200
        call_count = 0

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        instance.with_retry do
          call_count += 1
          raise wrapped(GRPC::Unavailable.new("temporary")) if call_count == 1

          "success"
        end
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        expect(elapsed).to be_between(0.15, 2.0)
      end

      it "retries once on a retryable error" do
        call_count = 0
        expect do
          instance.with_retry do
            call_count += 1
            raise wrapped(GRPC::Unavailable.new("connection refused"))
          end
        end.to raise_error(Busybee::GRPC::Error)
        expect(call_count).to eq(2)
      end

      it "succeeds on retry" do
        call_count = 0
        result = instance.with_retry do
          call_count += 1
          raise wrapped(GRPC::Unavailable.new("temporary")) if call_count == 1

          "success"
        end
        expect(result).to eq("success")
        expect(call_count).to eq(2)
      end

      it "does not retry a non-retryable error" do
        call_count = 0
        expect do
          instance.with_retry do
            call_count += 1
            raise wrapped(GRPC::InvalidArgument.new("bad request"))
          end
        end.to raise_error(Busybee::GRPC::Error)
        expect(call_count).to eq(1)
      end

      it "re-raises the same translated error object, without re-wrapping" do
        original = wrapped(GRPC::InvalidArgument.new("bad request"))
        returned = nil
        begin
          instance.with_retry { raise original }
        rescue Busybee::GRPC::Error => e
          returned = e
        end
        expect(returned).to be(original)
      end
    end
  end
end
