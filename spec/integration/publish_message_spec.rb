# frozen_string_literal: true

require "json"

RSpec.describe "Publish Message", :integration do
  # This test verifies that we can publish messages to process instances
  # using the PublishMessage GRPC operation. The waiting_process.bpmn has
  # a message intermediate catch event that waits for a message before completing.

  let(:bpmn_path) { File.expand_path("../fixtures/waiting_process.bpmn", __dir__) }

  it "publishes a message to continue a waiting process instance" do # rubocop:disable RSpec/ExampleLength
    client = grpc_client

    # Deploy process and create instance with a correlation ID variable
    deployment = deploy_process(client, bpmn_path)
    process_id = deployment[:process_id]

    # Use a unique correlation ID for this instance
    correlation_id = SecureRandom.hex(8)
    variables = JSON.generate({ correlationId: correlation_id })

    instance_response = create_process_instance(client, process_id, variables)
    process_instance_key = instance_response.processInstanceKey

    # The process is now waiting at the message intermediate catch event
    # Publish a message to continue the process
    # The waiting_process.bpmn uses correlationKey="=correlationId"
    request = Busybee::GRPC::PublishMessageRequest.new(
      name: "continue-message",
      correlationKey: correlation_id
    )

    response = client.publish_message(request)

    # Verify the message was published
    expect(response).to be_a(Busybee::GRPC::PublishMessageResponse)
    expect(response.key).to be > 0

    # Wait for the process to complete
    sleep 2

    # Verify the process has completed by trying to cancel it
    # This should fail with NotFound because the process already completed
    cancel_request = Busybee::GRPC::CancelProcessInstanceRequest.new(
      processInstanceKey: process_instance_key
    )

    expect do
      client.cancel_process_instance(cancel_request)
    end.to raise_error(GRPC::NotFound)
  end

  it "handles errors when publishing message with non-matching correlation key" do
    client = grpc_client

    # Try to publish a message that won't match any waiting process
    request = Busybee::GRPC::PublishMessageRequest.new(
      name: "continue-message",
      correlationKey: "non-existent-correlation-key",
      timeToLive: 1000 # 1 second TTL
    )

    # This should NOT raise an error - messages are published regardless
    # of whether there's a matching subscription
    response = client.publish_message(request)

    expect(response).to be_a(Busybee::GRPC::PublishMessageResponse)
    expect(response.key).to be > 0
  end
end
