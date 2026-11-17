# frozen_string_literal: true

require_relative "fault_injection_gateway" # sibling file; spec/support is not on the load path

# Thin RSpec integration over the plain-Ruby harness: tag an example group
# :gateway and it gets a fresh, started gateway, torn down after each example.
#
# Not :integration, whose skip_unless_zeebe_available would skip these specs when
# local Zeebe is down. Boot and teardown take ~2ms.
RSpec.shared_context "with a fault-injection gateway" do
  let(:gateway) { FaultInjectionGateway.new.start }

  after { gateway.stop }
end

RSpec.configure do |config|
  config.include_context "with a fault-injection gateway", :gateway
end
