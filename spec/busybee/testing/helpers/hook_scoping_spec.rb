# frozen_string_literal: true

require "busybee/testing"

RSpec.describe Busybee::Testing::Helpers::HookScoping do
  around do |example|
    Busybee::Hooks.isolated do
      Busybee::Hooks.reset!
      Busybee::Hooks::HOOK_TYPES.each { |type| Busybee::Hooks.register(type, proc {}) }
      example.run
    end
  end

  def suppressed = Busybee::Hooks::HOOK_TYPES.select { |type| Busybee::Hooks.hooks_for(type).empty? }

  describe "#without_hooks" do
    it "suppresses the hooks with the given word in their name, and only those" do
      expect(without_hooks(:perform) { suppressed }).to eq(%i[before_perform around_perform after_perform])
      expect(without_hooks(:job) { suppressed }).to eq(
        %i[on_job_activated on_job_executed on_job_not_executed around_job_execution]
      )
      expect(without_hooks(:worker) { suppressed }).to eq(
        %i[on_worker_started on_worker_stop_requested on_worker_stopping on_worker_shutdown]
      )
      expect(without_hooks(:call) { suppressed }).to eq(%i[before_call around_call after_call])
    end

    it "suppresses everything for :all" do
      expect(without_hooks(:all) { suppressed }).to eq(Busybee::Hooks::HOOK_TYPES)
    end

    it "composes a list" do
      expect(without_hooks(:perform, :call) { suppressed }).to eq(
        %i[before_perform around_perform after_perform before_call around_call after_call]
      )
    end

    it "composes by nesting, restoring the outer scope on the way out" do
      inner = outer_after = nil
      without_hooks(:perform) do
        inner = without_hooks(:call) { suppressed }
        outer_after = suppressed
      end

      expect(inner).to eq(%i[before_perform around_perform after_perform before_call around_call after_call])
      expect(outer_after).to eq(%i[before_perform around_perform after_perform])
    end

    it "restores every hook afterwards, even when the block raises" do
      expect { without_hooks(:all) { raise "boom" } }.to raise_error("boom")

      expect(suppressed).to be_empty
    end

    it "refuses an unknown word before suppressing anything" do
      expect { without_hooks(:perform, :jobs) { nil } }.to raise_error(ArgumentError, /:jobs.*:perform, :job/)
    end
  end
end
