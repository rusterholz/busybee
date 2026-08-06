# frozen_string_literal: true

require_relative "fault_injection_gateway" # sibling file; spec/support is not on the load path

# Thin RSpec integration over the plain-Ruby harness: tag an example group
# :gateway and it gets a fresh, started gateway, torn down after each example.
#
# Deliberately NOT tagged :integration. That tag carries skip_unless_zeebe_available
# (integration_helper.rb), so adopting it would skip these specs precisely when local
# Zeebe is down — the opposite of what a self-contained gateway is for. Boot and
# teardown measure ~2ms, so one gateway per example is affordable.
RSpec.shared_context "with a fault-injection gateway" do
  let(:gateway) { FaultInjectionGateway.new.start }

  after { gateway.stop }
end

RSpec.configure do |config|
  config.include_context "with a fault-injection gateway", :gateway
end
