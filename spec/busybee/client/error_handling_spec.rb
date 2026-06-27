# frozen_string_literal: true

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
        Busybee.grpc_retry_delay_ms = 1 # Fast for tests
      end

      after do
        Busybee.grpc_retry_enabled = nil
        Busybee.grpc_retry_delay_ms = nil
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
