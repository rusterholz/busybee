# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

# The busybee command loading a Rails app, run as a real process in a directory
# holding nothing but the app's config/environment.rb.
RSpec.describe "the busybee command's Rails boot", :busybee_command, :gateway, :rails do # rubocop:disable RSpec/DescribeClass
  let(:app_dir) { File.realpath(Dir.mktmpdir) }

  after { FileUtils.rm_rf(app_dir) }

  # A bare app whose own logger tags each line, so a line shows which logger wrote it.
  def rails_app(before_app: "", config: "")
    <<~RUBY
      require "logger"
      require "rails"
      #{before_app}
      class BootApp < Rails::Application
        config.root = File.expand_path("..", __dir__)
        config.eager_load = false
        config.logger = Logger.new($stdout).tap { |logger| logger.formatter = proc { |*, line| "RAILS \#{line}\\n" } }
        config.log_level = :info
        #{config}
      end
      BootApp.initialize!
    RUBY
  end

  def run_in_app(environment, *args)
    if environment
      FileUtils.mkdir_p(File.join(app_dir, "config"))
      File.write(File.join(app_dir, "config/environment.rb"), environment)
    end
    run_to_completion(*args, chdir: app_dir)
  end

  def failure_line(error)
    "[busybee] Failed to load Rails environment in #{app_dir}; set BUSYBEE_SKIP_RAILS=1 if this is not a " \
      "Rails app (#{error})"
  end

  def continuing_line = "[busybee] Continuing without Rails, no config/environment.rb in #{app_dir}"

  it "logs to stdout while Rails boots, then through Rails.logger" do
    result = run_in_app(rails_app(before_app: "Busybee.default_message_ttl = 30"))

    expect(result.status&.exitstatus).to eq(0), describe_exit(result)
    expect(result.stdout.lines.first).to match(/\AW, \[[^\]]+\]  WARN -- : \[busybee\] default_message_ttl: 30ms /)
    expect(result.stdout.lines.drop(1)).to eq(worker_messages.map { |line| "RAILS #{line}\n" })
  end

  it "logs to stdout, and carries on, where there is no config/environment.rb" do
    result = run_in_app(nil)

    expect(result.status&.exitstatus).to eq(0), describe_exit(result)
    expect(result.stdout.lines.first).to match(/\AI, \[[^\]]+\]  INFO -- : \[busybee\] Continuing without Rails, /)
    expect(messages(result.stdout)).to eq([continuing_line, *worker_messages])
  end

  it "writes its first line in the --log-format given" do
    result = run_in_app(nil, "-l", "json")

    expect(JSON.parse(result.stdout.lines.first[/\{.*\}/])).to include("level" => "info", "message" => continuing_line)
  end

  it "exits 1 when config/environment.rb raises, logging why on stdout and the backtrace on stderr" do
    result = run_in_app("raise 'database.yml missing'\n")

    expect(result.status&.exitstatus).to eq(1), describe_exit(result)
    expect(result.stdout).to match(
      /\AE, \[[^\]]+\] ERROR -- : #{Regexp.escape(failure_line('RuntimeError: database.yml missing'))}\n\z/
    )
    expect(result.stderr).to match(%r{config/environment\.rb:1:in .*database\.yml missing \(RuntimeError\)})
    expect(result.stderr).not_to include("WorkerNotFound")
  end

  it "exits 1 when a gem config/environment.rb requires is missing" do
    result = run_in_app(rails_app(before_app: "require 'busybee_spec_missing_gem'"))

    expect(result.status&.exitstatus).to eq(1), describe_exit(result)
    expect(messages(result.stdout)).to eq(
      [failure_line("LoadError: cannot load such file -- busybee_spec_missing_gem")]
    )
    expect(result.stderr).to include("cannot load such file -- busybee_spec_missing_gem (LoadError)")
  end

  it "exits 1 when config/environment.rb doesn't parse" do
    result = run_in_app("def unfinished(\n")

    expect(result.status&.exitstatus).to eq(1), describe_exit(result)
    expect(result.stdout).to include("ERROR -- : [busybee] Failed to load Rails environment in #{app_dir}; ")
    expect(result.stdout).to include("(SyntaxError: ")
    expect(result.stderr).to include("(SyntaxError)")
  end

  it "exits 1 with only the backtrace when the app turned logging off before it failed" do
    result = run_in_app(rails_app(config: <<~RUBY))
      config.x.busybee.logger = false
      initializer("boot_app.fail", after: "busybee.configure") { raise "late initializer failed" }
    RUBY

    expect(result.status&.exitstatus).to eq(1), describe_exit(result)
    expect(messages(result.stdout)).to eq([])
    expect(result.stderr).to include("late initializer failed (RuntimeError)")
  end

  it "stays silent when the app set its logger to nil before Rails booted" do
    result = run_in_app(rails_app(before_app: "Busybee.logger = nil"))

    expect(result.status&.exitstatus).to eq(0), describe_exit(result)
    expect(messages(result.stdout)).to eq([])
  end
end
