# frozen_string_literal: true

require "active_support/core_ext/numeric/time"

RSpec.describe Busybee::Client, "#publish_message" do
  shared_context "with deployed waiting process" do
    let(:bpmn_path) { File.expand_path("../../fixtures/waiting_process.bpmn", __dir__) }
    let(:process_id) { deploy_process(bpmn_path, uniquify: true)[:process_id] }
  end

  shared_examples "publish_message" do
    include_context "with deployed waiting process"

    it "publishes a message to continue a waiting process instance" do
      # Use a unique correlation ID for this instance
      correlation_id = SecureRandom.hex(8)

      # Create instance and test publish message operation
      with_process_instance(process_id, correlationId: correlation_id) do
        # The process is now waiting at the message intermediate catch event
        # Publish a message to continue the process
        message_key = client.publish_message("continue-message",
                                             correlation_key: correlation_id)

        # Verify the message was published
        expect(message_key).to be_a(Integer)
        expect(message_key).to be > 0

        # Verify the process completed after receiving the message
        assert_process_completed!
      end
    end

    it "publishes a message with explicit TTL in milliseconds" do
      correlation_id = SecureRandom.hex(8)

      with_process_instance(process_id, correlationId: correlation_id) do
        message_key = client.publish_message("continue-message",
                                             correlation_key: correlation_id,
                                             ttl: 30_000)

        expect(message_key).to be > 0
        assert_process_completed!
      end
    end

    it "publishes a message with TTL as Duration object" do
      correlation_id = SecureRandom.hex(8)

      with_process_instance(process_id, correlationId: correlation_id) do
        message_key = client.publish_message("continue-message",
                                             correlation_key: correlation_id,
                                             ttl: 30.seconds)

        expect(message_key).to be > 0
        assert_process_completed!
      end
    end

    it "publishes a message with variables" do
      correlation_id = SecureRandom.hex(8)

      with_process_instance(process_id, correlationId: correlation_id) do
        message_key = client.publish_message("continue-message",
                                             correlation_key: correlation_id,
                                             vars: { orderId: "123", amount: 99.99 })

        expect(message_key).to be > 0
        assert_process_completed!
      end
    end

    it "handles non-matching correlation key without error" do
      # Publish a message that won't match any waiting process
      # This should NOT raise an error - messages are published regardless
      message_key = client.publish_message("continue-message",
                                           correlation_key: "non-existent-correlation-key")

      expect(message_key).to be_a(Integer)
      expect(message_key).to be > 0
    end
  end

  context "with local Zeebe", :integration do
    around do |example|
      original = Busybee.credential_type
      Busybee.credential_type = :insecure
      example.run
      Busybee.credential_type = original
    end

    let(:client) { local_busybee_client }

    it_behaves_like "publish_message"
  end

  context "with Camunda Cloud", :camunda_cloud do
    around do |example|
      original = Busybee.credential_type
      Busybee.credential_type = :camunda_cloud
      example.run
      Busybee.credential_type = original
    end

    let(:client) { camunda_cloud_busybee_client }

    it_behaves_like "publish_message"
  end
end
