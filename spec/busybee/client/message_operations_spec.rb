# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/numeric/time"

RSpec.describe Busybee::Client::MessageOperations do
  let(:client) { Busybee::Client.new(insecure: true, cluster_address: "localhost:26500") }
  let(:stub) { instance_double(Busybee::GRPC::Gateway::Stub) }

  before { allow(client.credentials).to receive(:grpc_stub).and_return(stub) }

  describe "#publish_message" do
    it "publishes a message and returns the message key" do
      response = double(key: 12345)
      allow(stub).to receive(:publish_message).and_return(response)

      result = client.publish_message("order-ready", correlation_key: "order-123", ttl: 60_000)

      expect(result).to eq(12345)
    end

    it "supports variables" do
      response = double(key: 12345)
      allow(stub).to receive(:publish_message).with(
        having_attributes(variables: '{"orderId":123}')
      ).and_return(response)

      client.publish_message("order-ready", correlation_key: "order-123", ttl: 60_000, vars: { orderId: 123 })

      expect(stub).to have_received(:publish_message).with(
        having_attributes(variables: '{"orderId":123}')
      )
    end

    it "supports ttl in milliseconds" do
      response = double(key: 12345)
      allow(stub).to receive(:publish_message).with(
        having_attributes(timeToLive: 5000)
      ).and_return(response)

      client.publish_message("order-ready", correlation_key: "order-123", ttl: 5000)

      expect(stub).to have_received(:publish_message).with(
        having_attributes(timeToLive: 5000)
      )
    end

    it "supports duration objects with in_milliseconds method" do
      duration = 30.seconds
      response = double(key: 12345)
      allow(stub).to receive(:publish_message).with(
        having_attributes(timeToLive: 30000)
      ).and_return(response)

      client.publish_message("order-ready", correlation_key: "order-123", ttl: duration)

      expect(stub).to have_received(:publish_message).with(
        having_attributes(timeToLive: 30000)
      )
    end

    it "supports tenant_id" do
      response = double(key: 12345)
      allow(stub).to receive(:publish_message).with(
        having_attributes(tenantId: "tenant-a")
      ).and_return(response)

      client.publish_message("order-ready", correlation_key: "order-123", ttl: 60_000, tenant_id: "tenant-a")

      expect(stub).to have_received(:publish_message).with(
        having_attributes(tenantId: "tenant-a")
      )
    end

    it "uses configured default_message_ttl when ttl not provided" do
      Busybee.default_message_ttl = 60_000
      response = double(key: 12345)
      allow(stub).to receive(:publish_message).with(
        having_attributes(timeToLive: 60_000)
      ).and_return(response)

      client.publish_message("order-ready", correlation_key: "order-123")

      expect(stub).to have_received(:publish_message).with(
        having_attributes(timeToLive: 60_000)
      )
    ensure
      Busybee.default_message_ttl = nil
    end

    it "falls back to Defaults::DEFAULT_MESSAGE_TTL_MS when not configured" do
      Busybee.default_message_ttl = nil
      response = double(key: 12345)
      allow(stub).to receive(:publish_message).with(
        having_attributes(timeToLive: Busybee::Defaults::DEFAULT_MESSAGE_TTL_MS)
      ).and_return(response)

      client.publish_message("order-ready", correlation_key: "order-123")

      expect(stub).to have_received(:publish_message).with(
        having_attributes(timeToLive: Busybee::Defaults::DEFAULT_MESSAGE_TTL_MS)
      )
    end

    it "supports Duration objects as default_message_ttl" do
      Busybee.default_message_ttl = 45.seconds
      response = double(key: 12345)
      allow(stub).to receive(:publish_message).with(
        having_attributes(timeToLive: 45_000)
      ).and_return(response)

      client.publish_message("order-ready", correlation_key: "order-123")

      expect(stub).to have_received(:publish_message).with(
        having_attributes(timeToLive: 45_000)
      )
    ensure
      Busybee.default_message_ttl = nil
    end

    it "allows explicit ttl to override default_message_ttl with Duration" do
      Busybee.default_message_ttl = 60_000
      response = double(key: 12345)
      allow(stub).to receive(:publish_message).with(
        having_attributes(timeToLive: 20_000)
      ).and_return(response)

      client.publish_message("order-ready", correlation_key: "order-123", ttl: 20.seconds)

      expect(stub).to have_received(:publish_message).with(
        having_attributes(timeToLive: 20_000)
      )
    ensure
      Busybee.default_message_ttl = nil
    end

    it "wraps GRPC errors in Busybee::GRPC::Error" do
      allow(stub).to receive(:publish_message).and_raise(GRPC::InvalidArgument.new("invalid message"))

      expect { client.publish_message("bad-message", correlation_key: "key", ttl: 60_000) }.
        to raise_error(Busybee::GRPC::Error) do |error|
        expect(error.cause).to be_a(GRPC::InvalidArgument)
        expect(error.grpc_status).to eq(:invalid_argument)
      end
    end

    it "raises ArgumentError when vars is not a Hash" do
      expect do
        client.publish_message("order-ready", correlation_key: "order-123", ttl: 60_000, vars: "invalid")
      end.to raise_error(ArgumentError, "vars must be a Hash")
    end
  end

  describe "#broadcast_signal" do
    it "broadcasts a signal and returns the signal key" do
      response = double(key: 54321)
      allow(stub).to receive(:broadcast_signal).and_return(response)

      result = client.broadcast_signal("cancel-all-orders")

      expect(result).to eq(54321)
    end

    it "supports variables" do
      response = double(key: 54321)
      allow(stub).to receive(:broadcast_signal).with(
        having_attributes(variables: '{"reason":"system-maintenance"}')
      ).and_return(response)

      client.broadcast_signal("cancel-all-orders", vars: { reason: "system-maintenance" })

      expect(stub).to have_received(:broadcast_signal).with(
        having_attributes(variables: '{"reason":"system-maintenance"}')
      )
    end

    it "supports tenant_id" do
      response = double(key: 54321)
      allow(stub).to receive(:broadcast_signal).with(
        having_attributes(tenantId: "tenant-a")
      ).and_return(response)

      client.broadcast_signal("cancel-all-orders", tenant_id: "tenant-a")

      expect(stub).to have_received(:broadcast_signal).with(
        having_attributes(tenantId: "tenant-a")
      )
    end

    it "wraps GRPC errors in Busybee::GRPC::Error" do
      allow(stub).to receive(:broadcast_signal).and_raise(GRPC::InvalidArgument.new("invalid signal"))

      expect { client.broadcast_signal("bad-signal") }.to raise_error(Busybee::GRPC::Error) do |error|
        expect(error.cause).to be_a(GRPC::InvalidArgument)
        expect(error.grpc_status).to eq(:invalid_argument)
      end
    end

    it "raises ArgumentError when vars is not a Hash" do
      expect do
        client.broadcast_signal("cancel-all-orders", vars: "invalid")
      end.to raise_error(ArgumentError, "vars must be a Hash")
    end
  end
end
