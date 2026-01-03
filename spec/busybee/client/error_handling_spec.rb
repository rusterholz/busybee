# frozen_string_literal: true

require "spec_helper"
require "busybee/client/error_handling"

RSpec.describe Busybee::Client::ErrorHandling do
  let(:test_class) do
    Class.new { include Busybee::Client::ErrorHandling }
  end
  let(:instance) { test_class.new }

  describe "#with_retry" do
    context "when retry is disabled" do
      before { Busybee.grpc_retry_enabled = false }
      after { Busybee.grpc_retry_enabled = nil }

      it "does not retry on transient errors" do
        call_count = 0
        expect do
          instance.with_retry do
            call_count += 1
            raise GRPC::Unavailable, "connection refused"
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

      it "retries once on transient errors" do
        call_count = 0
        expect do
          instance.with_retry do
            call_count += 1
            raise GRPC::Unavailable, "connection refused"
          end
        end.to raise_error(Busybee::GRPC::Error)
        expect(call_count).to eq(2)
      end

      it "succeeds on retry" do
        call_count = 0
        result = instance.with_retry do
          call_count += 1
          raise GRPC::Unavailable, "temporary" if call_count == 1

          "success"
        end
        expect(result).to eq("success")
        expect(call_count).to eq(2)
      end
    end
  end
end
