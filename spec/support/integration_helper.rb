# frozen_string_literal: true

# Integration test helper for testing against a real Zeebe instance
#
# Usage:
#   1. Start Zeebe: rake zeebe:start && rake zeebe:health
#   2. Run tests: RUN_INTEGRATION_TESTS=1 bundle exec rspec --tag integration
#
# Tests will skip gracefully if Zeebe is not running.

module IntegrationHelpers
  # Default Zeebe gateway address when running via Docker Compose
  ZEEBE_ADDRESS = "localhost:26500"

  # Default credentials for Zeebe (demo/demo)
  # These are the default credentials for the Camunda platform when running via Docker Compose
  # Override with ZEEBE_USERNAME and ZEEBE_PASSWORD environment variables if needed
  ZEEBE_USERNAME = ENV.fetch("ZEEBE_USERNAME", "demo")
  ZEEBE_PASSWORD = ENV.fetch("ZEEBE_PASSWORD", "demo")

  # Timeout for Zeebe connection checks (in seconds)
  CONNECTION_TIMEOUT = 5

  # Creates GRPC metadata with authentication headers
  #
  # @return [Hash] GRPC metadata with authorization header
  def auth_metadata
    credentials = "#{ZEEBE_USERNAME}:#{ZEEBE_PASSWORD}"
    encoded = Base64.strict_encode64(credentials)
    { "authorization" => "Basic #{encoded}" }
  end

  # Creates a GRPC client stub for connecting to Zeebe
  #
  # @return [Busybee::GRPC::Gateway::Stub] GRPC client stub
  def grpc_client
    Busybee::GRPC::Gateway::Stub.new(
      ZEEBE_ADDRESS,
      :this_channel_is_insecure
    )
  end

  # Checks if Zeebe is available and responsive
  #
  # This method attempts to connect to Zeebe and call the topology endpoint
  # to verify the service is running and healthy.
  #
  # @return [Boolean] true if Zeebe is available, false otherwise
  def zeebe_available?
    client = grpc_client
    request = Busybee::GRPC::TopologyRequest.new
    # With unprotectedApi: true, no auth metadata needed
    client.topology(request, deadline: Time.now + CONNECTION_TIMEOUT)
    true
  rescue GRPC::Unavailable, GRPC::DeadlineExceeded, GRPC::Core::CallError, GRPC::Unauthenticated => e
    warn "\n[Integration Test] Zeebe not available: #{e.class} - #{e.message}"
    false
  end

  # Skips the current test if Zeebe is not available
  #
  # Call this in a before block to gracefully skip tests when Zeebe
  # is not running:
  #
  #   before do
  #     skip_unless_zeebe_available
  #   end
  def skip_unless_zeebe_available
    skip "Zeebe is not running (start with: rake zeebe:start)" unless zeebe_available?
  end

  # Generates a unique BPMN process ID for test isolation
  #
  # This ensures each test can deploy its own process without conflicting
  # with processes deployed by other tests or previous test runs.
  #
  # @return [String] A unique process ID like "test-process-abc123"
  def unique_process_id
    "test-process-#{SecureRandom.hex(6)}"
  end

  # Reads a BPMN file and replaces the process ID with a unique one
  #
  # This enables test isolation by ensuring each test has its own
  # unique process definition that won't conflict with others.
  #
  # @param bpmn_path [String] Path to the BPMN file to read
  # @param process_id [String] Optional custom process ID (generates random if not provided)
  # @return [String] BPMN content with replaced process ID
  def bpmn_with_unique_id(bpmn_path, process_id = nil)
    process_id ||= unique_process_id
    bpmn_content = File.read(bpmn_path)

    # Replace the process ID in the BPMN XML
    # The process ID appears in:
    # - <bpmn:process id="..." - the actual process element
    # - <bpmndi:BPMNPlane ... bpmnElement="..." - diagram reference to the process
    # We must NOT replace bpmnElement for shapes/edges (those reference StartEvent_1, etc.)
    bpmn_content
      .gsub(/(<bpmn:process id=")[^"]+/, "\\1#{process_id}")
      .gsub(/(<bpmndi:BPMNPlane\s+[^>]*bpmnElement=")[^"]+/, "\\1#{process_id}")
  end
end

RSpec.configure do |config|
  # Include integration helpers in all integration tests
  config.include IntegrationHelpers, integration: true

  # Check Zeebe availability before running integration tests
  config.before(:each, integration: true) do
    skip_unless_zeebe_available
  end
end
