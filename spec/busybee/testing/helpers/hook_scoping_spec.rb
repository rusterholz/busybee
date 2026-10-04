# frozen_string_literal: true

require "busybee/testing"

RSpec.describe Busybee::Testing::Helpers::HookScoping do
  around do |example|
    isolate_busybee_hooks do
      Busybee::Hooks::HOOK_TYPES.each { |type| Busybee::Hooks.register(type, proc {}) }
      example.run
    end
  end

  def suppressed = Busybee::Hooks::HOOK_TYPES.select { |type| Busybee::Hooks.hooks_for(type).empty? }

  describe "#without_busybee_hooks" do
    it "suppresses the hooks with the given word in their name, and only those" do
      expect(without_busybee_hooks(:perform) { suppressed }).to eq(%i[before_perform around_perform after_perform])
      expect(without_busybee_hooks(:job) { suppressed }).to eq(
        %i[on_job_activated on_job_executed on_job_not_executed around_job_execution]
      )
      expect(without_busybee_hooks(:worker) { suppressed }).to eq(
        %i[on_worker_started on_worker_stop_requested on_worker_stopping on_worker_shutdown]
      )
      expect(without_busybee_hooks(:call) { suppressed }).to eq(%i[before_call around_call after_call])
    end

    it "suppresses everything for :all" do
      expect(without_busybee_hooks(:all) { suppressed }).to eq(Busybee::Hooks::HOOK_TYPES)
    end

    it "composes a list" do
      expect(without_busybee_hooks(:perform, :call) { suppressed }).to eq(
        %i[before_perform around_perform after_perform before_call around_call after_call]
      )
    end

    it "composes by nesting, restoring the outer scope on the way out" do
      inner = outer_after = nil
      without_busybee_hooks(:perform) do
        inner = without_busybee_hooks(:call) { suppressed }
        outer_after = suppressed
      end

      expect(inner).to eq(%i[before_perform around_perform after_perform before_call around_call after_call])
      expect(outer_after).to eq(%i[before_perform around_perform after_perform])
    end

    it "restores every hook afterwards, even when the block raises" do
      expect { without_busybee_hooks(:all) { raise "boom" } }.to raise_error("boom")

      expect(suppressed).to be_empty
    end

    it "refuses an unknown word before suppressing anything" do
      expect { without_busybee_hooks(:perform, :jobs) { nil } }.to raise_error(ArgumentError, /:jobs.*:perform, :job/)
    end

    it "empties the registry for :all, while hooks registered inside still run, and are gone afterwards" do
      fired = []
      without_busybee_hooks(:all) do
        Busybee::Hooks.after_perform { |_job| fired << :inside }
        Busybee::Hooks.run(:after_perform, nil)
      end

      expect(fired).to eq([:inside])
      expect(Busybee::Hooks.hooks_for(:after_perform).size).to eq(1)
    end
  end

  describe "#isolate_busybee_hooks" do
    it "keeps every registered hook in place while the block runs" do
      expect(isolate_busybee_hooks { suppressed }).to be_empty
    end

    it "discards registrations made inside the block, even when it raises" do
      expect do
        isolate_busybee_hooks do
          Busybee::Hooks.after_perform { nil }
          raise "boom"
        end
      end.to raise_error("boom")

      expect(Busybee::Hooks.hooks_for(:after_perform).size).to eq(1)
    end

    it "returns the block's value" do
      expect(isolate_busybee_hooks { :computed }).to eq(:computed)
    end
  end
end
