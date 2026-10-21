# frozen_string_literal: true

require "busybee/runner/exit_immediately"

# The process-wide fire alarm, read and raised through what extends it.
RSpec.describe Busybee::Runner::ExitImmediately do
  let(:alarm) { Module.new.extend(described_class) }

  it "is quiet, with no reason, until raised" do
    expect([alarm.exit_immediately?, alarm.exit_immediately_reason]).to eq([false, nil])
  end

  it "names the fire once raised" do
    alarm.exit_immediately!(reason: :kill)

    expect([alarm.exit_immediately?, alarm.exit_immediately_reason]).to eq([true, :kill])
  end

  it "keeps the first fire's reason" do
    alarm.exit_immediately!(reason: :crash)
    alarm.exit_immediately!(reason: :kill)

    expect(alarm.exit_immediately_reason).to eq(:crash)
  end

  it "is raised as :crash when given no reason" do
    alarm.exit_immediately!(reason: nil)

    expect([alarm.exit_immediately?, alarm.exit_immediately_reason]).to eq([true, :crash])
  end

  it "is one alarm for everything that extends it" do
    Module.new.extend(described_class).exit_immediately!(reason: :kill)

    expect([alarm.exit_immediately_reason, Busybee::Runner.exit_immediately_reason]).to eq(%i[kill kill])
  end
end
