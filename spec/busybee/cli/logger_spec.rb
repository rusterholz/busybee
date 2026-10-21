# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

# The busybee command's own logger, run as a real process outside Rails.
RSpec.describe "the busybee command's logger", :busybee_command, :gateway do # rubocop:disable RSpec/DescribeClass
  def run_outside_rails(*args, hold_until_logged: false)
    Dir.mktmpdir do |dir|
      run_to_completion(*args, chdir: dir, env: { "BUSYBEE_SKIP_RAILS" => "1" }, hold_until_logged: hold_until_logged)
    end
  end

  it "logs each line to stdout at info as it happens" do
    result = run_outside_rails(hold_until_logged: true)

    expect(result.status&.exitstatus).to eq(0), describe_exit(result)
    expect(result.stdout_while_running).to match(/INFO -- : \[busybee\] Completed logging_stream job ##{job.key}\n/)
    expect(messages(result.stdout)).to eq(worker_messages)
    expect(result.stdout.lines).to all(match(/\AI, \[\S+ #\d+\]  INFO -- : \[busybee\] /))
    expect(result.stdout.lines.size).to eq(worker_messages.size)
    expect(result.stderr).to eq("")
  end

  it "logs one bare JSON object a line under --log-format json" do
    result = run_outside_rails("-l", "json")

    lines = result.stdout.lines.map { |line| JSON.parse(line) }
    expect(lines.map { |line| line.values_at("level", "message") }).to eq(worker_messages.map { |line| ["info", line] })
  end

  it "carries on without a word about Rails when the bundle has no rails" do
    result = Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config/environment.rb"), "raise 'never loaded'\n")
      run_to_completion(chdir: dir, env: BusybeeCommand::WITHOUT_RAILS)
    end

    expect(result.status&.exitstatus).to eq(0), describe_exit(result)
    expect(messages(result.stdout)).to eq(worker_messages)
  end
end
