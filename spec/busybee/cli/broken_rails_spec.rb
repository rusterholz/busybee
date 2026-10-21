# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# A rails in the bundle that can't load: a stand-in rails.rb, first on the load
# path of a bundle with no rails of its own, requires a feature that isn't there.
RSpec.describe "the busybee command with a broken rails", :busybee_command, :gateway do # rubocop:disable RSpec/DescribeClass
  let(:dir) { File.realpath(Dir.mktmpdir) }

  after { FileUtils.rm_rf(dir) }

  it "exits 1, logging why on stdout and the backtrace on stderr" do
    File.write(File.join(dir, "rails.rb"), "require 'busybee_spec_missing_rails_dependency'\n")
    result = run_to_completion(chdir: dir, env: BusybeeCommand::WITHOUT_RAILS.merge("RUBYLIB" => dir))

    expect(result.status&.exitstatus).to eq(1), describe_exit(result)
    expect(messages(result.stdout)).to eq(
      ["[busybee] Failed to load Rails environment in #{dir}; set BUSYBEE_SKIP_RAILS=1 if this is not a " \
       "Rails app (LoadError: cannot load such file -- busybee_spec_missing_rails_dependency)"]
    )
    expect(result.stderr).to include("cannot load such file -- busybee_spec_missing_rails_dependency (LoadError)")
  end
end
