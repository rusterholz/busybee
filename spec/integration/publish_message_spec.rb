# frozen_string_literal: true

require "json"

RSpec.describe "Publish Message", :integration do
  # This test verifies that we can publish messages to process instances
  # using the PublishMessage GRPC operation. The waiting_process.bpmn has
  # a message intermediate catch event that waits for a message before completing.

  let(:bpmn_path) { File.expand_path("../fixtures/waiting_process.bpmn", __dir__) }
  let(:process_id) { deploy_process(bpmn_path, uniquify: true)[:process_id] }

  it "publishes a message to continue a waiting process instance" do
    # Use a unique correlation ID for this instance
    correlation_id = SecureRandom.hex(8)

    # Create instance and test publish message operation
    with_process_instance(process_id, correlationId: correlation_id) do
      # The process is now waiting at the message intermediate catch event
      # Publish a message to continue the process (this is what we're testing)
      # The waiting_process.bpmn uses correlationKey="=correlationId"
      request = Busybee::GRPC::PublishMessageRequest.new(
        name: "continue-message",
        correlationKey: correlation_id
      )

      response = grpc_client.publish_message(request)

      # Verify the message was published
      expect(response).to be_a(Busybee::GRPC::PublishMessageResponse)
      expect(response.key).to be > 0

      # Verify the process completed after receiving the message
      assert_process_completed!
    end
  end

  it "handles errors when publishing message with non-matching correlation key" do
    # Try to publish a message that won't match any waiting process
    request = Busybee::GRPC::PublishMessageRequest.new(
      name: "continue-message",
      correlationKey: "non-existent-correlation-key",
      timeToLive: 1000 # 1 second TTL
    )

    # This should NOT raise an error - messages are published regardless
    # of whether there's a matching subscription
    response = grpc_client.publish_message(request)

    expect(response).to be_a(Busybee::GRPC::PublishMessageResponse)
    expect(response.key).to be > 0
  end
end
