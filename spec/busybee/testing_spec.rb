# frozen_string_literal: true

require "busybee/testing"

RSpec.describe Busybee::Testing do
  it "is defined as a module" do
    expect(described_class).to be_a(Module)
  end

  describe "the without_hooks metadata" do
    # Registered outside every example's around, so what an example sees is
    # exactly what the metadata left of them.
    before(:context) do # rubocop:disable RSpec/BeforeAfterAll
      Busybee::Hooks.after_call { nil }
      Busybee::Hooks.after_perform { nil }
    end

    after(:context) do # rubocop:disable RSpec/BeforeAfterAll
      Busybee::Hooks.hooks_for(:after_call).pop
      Busybee::Hooks.hooks_for(:after_perform).pop
    end

    def registered?(type) = Busybee::Hooks.hooks_for(type).any?

    context "when a group names hooks", without_hooks: [:call] do
      it "suppresses them for every example in it" do
        expect(registered?(:after_call)).to be(false)
        expect(registered?(:after_perform)).to be(true)
      end

      it "is undone for one example by an empty list", without_hooks: [] do
        expect(registered?(:after_call)).to be(true)
      end

      it "is replaced, not added to, by an example's own list", without_hooks: [:perform] do
        expect(registered?(:after_call)).to be(true)
        expect(registered?(:after_perform)).to be(false)
      end
    end

    context "without the metadata" do
      it "suppresses nothing" do
        expect(registered?(:after_call)).to be(true)
      end
    end
  end
end
