# frozen_string_literal: true

require "busybee/grpc/error"

RSpec.describe Busybee::GRPC::Error do
  let(:grpc_error) { GRPC::Unavailable.new("connection refused") }

  it "wraps a GRPC error via automatic cause chaining" do
    wrapped = nil
    begin
      begin
        raise grpc_error
      rescue GRPC::BadStatus
        raise described_class, "Connection failed"
      end
    rescue described_class => e
      wrapped = e
    end

    expect(wrapped.cause).to eq(grpc_error)
    expect(wrapped.grpc_code).to eq(14)
    expect(wrapped.grpc_status).to eq(:unavailable)
    expect(wrapped.grpc_details).to eq("connection refused")
  end

  it "uses custom message with GRPC details appended" do
    wrapped = nil
    begin
      begin
        raise grpc_error
      rescue GRPC::BadStatus
        raise described_class, "Connection failed"
      end
    rescue described_class => e
      wrapped = e
    end

    expect(wrapped.message).to eq("Connection failed (connection refused)")
  end

  it "uses default message with GRPC details appended when no message provided" do
    wrapped = nil
    begin
      begin
        raise grpc_error
      rescue GRPC::BadStatus
        raise described_class
      end
    rescue described_class => e
      wrapped = e
    end

    expect(wrapped.message).to eq("GRPC request failed (connection refused)")
  end

  it "uses custom message when no cause present" do
    error = described_class.new("Custom error")
    expect(error.message).to eq("Custom error")
  end

  it "uses default message when no cause present" do
    error = described_class.new
    expect(error.message).to eq("GRPC request failed")
  end

  it "returns nil for grpc_code, grpc_status, and grpc_details when cause is not a GRPC error" do
    error = described_class.new("plain error")
    expect(error.grpc_code).to be_nil
    expect(error.grpc_status).to be_nil
    expect(error.grpc_details).to be_nil
  end
end
