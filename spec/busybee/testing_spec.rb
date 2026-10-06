# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tmpdir"

require "busybee/testing"

RSpec.describe Busybee::Testing do
  it "is defined as a module" do
    expect(described_class).to be_a(Module)
  end

  # Each suite runs in its own process, from a directory with no .rspec: this
  # suite includes the helpers everywhere, so nothing in it is un-opted.
  describe "which examples get the helpers" do
    def run_adopter_suite(name)
      suite = File.expand_path("testing/adopter_suites/#{name}.rb", __dir__)
      Dir.mktmpdir do |dir|
        _, err, = Open3.capture3(RbConfig.ruby, "-rbundler/setup", "-rrspec/core",
                                 "-e", "exit RSpec::Core::Runner.run(ARGV)",
                                 suite, "--format", "json", "--out", "results.json",
                                 chdir: dir)
        results = File.join(dir, "results.json")
        raise "suite didn't run:\n#{err}" unless File.exist?(results)

        JSON.parse(File.read(results))["examples"].to_h do |example|
          [example["full_description"], example.dig("exception", "message") || example["status"]]
        end
      end
    end

    it "gives them only to examples tagged :busybee" do
      expect(run_adopter_suite("default")).to eq(
        "the helpers module carries the matchers" => "passed",
        "a group that hasn't opted in has no busybee helper or matcher" => "passed",
        "a group that hasn't opted in has them all on an example tagged :busybee" => "passed",
        "a group that hasn't opted in still honors without_busybee_hooks metadata" => "passed",
        "a group tagged :busybee has them all" => "passed",
        "a group tagged :busybee when nested has them all" => "passed"
      )
    end

    it "gives them to every example after one line of configuration" do
      expect(run_adopter_suite("everywhere")).to eq(
        "a group that hasn't opted in has every busybee helper and matcher" => "passed"
      )
    end
  end

  describe "the without_busybee_hooks metadata" do
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

    context "when a group names hooks", without_busybee_hooks: [:call] do
      it "suppresses them for every example in it" do
        expect(registered?(:after_call)).to be(false)
        expect(registered?(:after_perform)).to be(true)
      end

      it "is undone for one example by an empty list", without_busybee_hooks: [] do
        expect(registered?(:after_call)).to be(true)
      end

      it "is replaced, not added to, by an example's own list", without_busybee_hooks: [:perform] do
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
