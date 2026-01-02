# frozen_string_literal: true

# Only run these tests with Rails loaded
RSpec.describe "Busybee::Railtie", skip: !defined?(Rails) do
  it "is defined when Rails is present" do
    expect(defined?(Busybee::Railtie)).to eq("constant")
  end

  it "is a Rails::Railtie" do
    expect(Busybee::Railtie.superclass).to eq(Rails::Railtie)
  end
end
