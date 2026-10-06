# frozen_string_literal: true

# An adopter's suite that requires busybee/testing and nothing more. Run in its
# own process by testing_spec.rb.
require "busybee/testing"

SURFACE = Busybee::Testing::Helpers.public_instance_methods

Busybee::Hooks.after_call { nil }

RSpec.describe "the helpers module" do
  it "carries the matchers" do
    expect(SURFACE).to include(:complete_job, :fail_job, :throw_bpmn_error_on, :have_received_variables,
                               :have_received_headers, :have_available_jobs, :have_an_available_job)
  end
end

RSpec.describe "a group that hasn't opted in" do
  it "has no busybee helper or matcher" do
    expect(methods & SURFACE).to be_empty
  end

  it "has them all on an example tagged :busybee", :busybee do
    expect(methods).to include(*SURFACE)
  end

  it "still honors without_busybee_hooks metadata", without_busybee_hooks: [:call] do
    expect(Busybee::Hooks.hooks_for(:after_call)).to be_empty
  end
end

RSpec.describe "a group tagged :busybee", :busybee do
  it "has them all" do
    expect(methods).to include(*SURFACE)
  end

  context "when nested" do
    it "has them all" do
      expect(methods).to include(*SURFACE)
    end
  end
end
