# frozen_string_literal: true

require "busybee/testing"

RSpec.describe Busybee::Testing::HookRegistry do
  let(:fired) { [] }

  # The gem registers no hooks of its own, so isolating is enough for a clean slate.
  around { |example| described_class.isolated { example.run } }

  def run(type) = Busybee::Hooks.run(type, nil)

  describe ".isolated" do
    it "discards registrations made inside the block" do
      described_class.isolated { Busybee::Hooks.before_perform { nil } }

      expect(Busybee::Hooks.hooks_for(:before_perform)).to be_empty
    end

    it "discards them even when the block raises" do
      expect do
        described_class.isolated do
          Busybee::Hooks.before_perform { nil }
          raise "boom"
        end
      end.to raise_error("boom")

      expect(Busybee::Hooks.hooks_for(:before_perform)).to be_empty
    end

    it "keeps registrations that predate the block" do
      Busybee::Hooks.before_perform { nil }

      described_class.isolated { Busybee::Hooks.after_perform { nil } }

      expect(Busybee::Hooks.hooks_for(:before_perform).size).to eq(1)
      expect(Busybee::Hooks.hooks_for(:after_perform)).to be_empty
    end

    it "returns the block's value" do
      expect(described_class.isolated { :computed }).to eq(:computed)
    end
  end

  describe ".with_only" do
    before do
      Busybee::Hooks.before_perform { fired << :before_perform }
      Busybee::Hooks.after_perform { fired << :after_perform }
    end

    it "runs the named types and suppresses the rest" do
      described_class.with_only(:before_perform) do
        run(:before_perform)
        run(:after_perform)
      end

      expect(fired).to eq([:before_perform])
    end

    it "suppresses every type when named none" do
      described_class.with_only do
        run(:before_perform)
        run(:after_perform)
      end

      expect(fired).to be_empty
    end

    it "restores the registry afterwards, even when the block raises" do
      expect { described_class.with_only { raise "boom" } }.to raise_error("boom")

      run(:after_perform)
      expect(fired).to eq([:after_perform])
    end

    it "returns the block's value" do
      expect(described_class.with_only(:before_perform) { :computed }).to eq(:computed)
    end

    it "rejects an unknown hook type rather than silently suppressing everything" do
      expect { described_class.with_only(:bogus) { nil } }.to raise_error(ArgumentError, /bogus/)
    end
  end

  describe ".suppressed?" do
    it "is false outside any with_only" do
      expect(described_class.suppressed?(:after_perform)).to be(false)
    end

    it "names what a with_only left out, and only that" do
      described_class.with_only(:before_perform) do
        expect(described_class.suppressed?(:after_perform)).to be(true)
        expect(described_class.suppressed?(:before_perform)).to be(false)
      end
    end

    it "accumulates through nesting, and unwinds with it" do
      described_class.with_only(:before_perform, :after_perform) do
        described_class.with_only(:before_perform) do
          expect(described_class.suppressed?(:after_perform)).to be(true)
        end
        expect(described_class.suppressed?(:after_perform)).to be(false)
      end
      expect(described_class.suppressed?(:on_job_activated)).to be(false)
    end

    it "unwinds even when the block raises" do
      expect { described_class.with_only { raise "boom" } }.to raise_error("boom")

      expect(described_class.suppressed?(:after_perform)).to be(false)
    end

    it "is untouched by a with_only that refuses an unknown type" do
      expect { described_class.with_only(:bogus) { nil } }.to raise_error(ArgumentError)

      expect(described_class.suppressed?(:after_perform)).to be(false)
    end
  end
end
