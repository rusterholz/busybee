# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"

# Each order boots its own Rails app in a fresh process: this suite has already
# loaded busybee, and a loaded Railtie can't be unloaded.
RSpec.describe "Busybee::Railtie", :rails do
  def boot_and_read_worker_name(first, second, before_boot: nil, from_rails: nil)
    script = <<~RUBY
      require "logger"
      require #{first.inspect}
      require #{second.inspect}
      Busybee.worker_name = #{before_boot.inspect}

      class LoadOrderApp < Rails::Application
        config.root = Dir.pwd
        config.eager_load = false
        config.logger = Logger.new(nil)
        config.x.busybee.grpc_retry_enabled = true
        config.x.busybee.worker_name = #{from_rails.inspect}
      end
      LoadOrderApp.initialize!

      print Busybee.worker_name
    RUBY

    Dir.mktmpdir do |dir|
      out, err, status = Open3.capture3(RbConfig.ruby, "-rbundler/setup", "-e", script, chdir: dir)
      raise "boot failed:\n#{err}" unless status.success?

      out
    end
  end

  it "applies config.x.busybee when busybee is required before Rails" do
    expect(boot_and_read_worker_name("busybee", "rails", from_rails: "load-order-worker")).to eq("load-order-worker")
  end

  it "applies config.x.busybee when Rails is required before busybee" do
    expect(boot_and_read_worker_name("rails", "busybee", from_rails: "load-order-worker")).to eq("load-order-worker")
  end

  it "keeps what a spec_helper configured before Rails booted, where config.x.busybee is silent" do
    expect(boot_and_read_worker_name("busybee", "rails", before_boot: "spec-helper-worker")).to eq("spec-helper-worker")
  end
end
