# frozen_string_literal: true

require "logger"
require "stringio"

require "busybee/logging"

RSpec.describe Busybee::Logging do
  let(:log_output) { StringIO.new }

  around do |example|
    original_logger = Busybee.logger
    Busybee.logger = logger
    example.run
    Busybee.logger = original_logger
    Busybee.log_format = :text
  end

  context "when in text mode" do
    let(:logger) do
      Logger.new(log_output).tap do |l|
        l.formatter = proc { |severity, _datetime, _progname, msg| "#{severity} -- : #{msg}\n" }
      end
    end

    before { Busybee.log_format = :text }

    describe ".info" do
      it "logs with [busybee] prefix" do
        described_class.info("test message")
        expect(log_output.string).to eq("INFO -- : [busybee] test message\n")
      end

      it "includes context" do
        described_class.info("test", job_key: 123)
        expect(log_output.string).to eq("INFO -- : [busybee] test (job_key: 123)\n")
      end
    end

    describe ".warn" do
      it "logs at warn level" do
        described_class.warn("warning message")
        expect(log_output.string).to eq("WARN -- : [busybee] warning message\n")
      end
    end

    describe ".error" do
      it "logs at error level" do
        described_class.error("error message")
        expect(log_output.string).to eq("ERROR -- : [busybee] error message\n")
      end
    end

    describe ".debug" do
      it "logs at debug level" do
        logger.level = Logger::DEBUG
        described_class.debug("debug message")
        expect(log_output.string).to eq("DEBUG -- : [busybee] debug message\n")
      end
    end
  end

  context "when in json mode" do
    let(:logger) do
      Logger.new(log_output).tap do |l|
        l.formatter = proc { |_severity, _datetime, _progname, msg| "#{msg}\n" }
      end
    end

    before { Busybee.log_format = :json }

    describe ".info" do
      it "logs as JSON with message, level, and context" do
        described_class.info("test message", job_key: 123)
        json = JSON.parse(log_output.string)
        expect(json).to eq({
                             "message" => "[busybee] test message",
                             "level" => "info",
                             "job_key" => 123
                           })
      end
    end

    describe ".warn" do
      it "logs as JSON with warn level" do
        described_class.warn("warning message")
        json = JSON.parse(log_output.string)
        expect(json).to eq({
                             "message" => "[busybee] warning message",
                             "level" => "warn"
                           })
      end
    end

    describe ".error" do
      it "logs as JSON with error level" do
        described_class.error("error message", error_code: 500)
        json = JSON.parse(log_output.string)
        expect(json).to eq({
                             "message" => "[busybee] error message",
                             "level" => "error",
                             "error_code" => 500
                           })
      end
    end

    describe ".debug" do
      it "logs as JSON with debug level" do
        logger.level = Logger::DEBUG
        described_class.debug("debug message")
        json = JSON.parse(log_output.string)
        expect(json).to eq({
                             "message" => "[busybee] debug message",
                             "level" => "debug"
                           })
      end
    end
  end

  context "when logger is nil" do
    let(:logger) { nil }

    it "does not raise error" do
      expect { described_class.info("test") }.not_to raise_error
    end
  end

  context "with concurrent logging" do
    let(:lines) { Queue.new }
    let(:logger) do
      Logger.new($stdout).tap do |l|
        l.formatter = proc do |_severity, _datetime, _progname, msg|
          lines << msg
          ""
        end
      end
    end

    let(:thread_count) { 10 }
    let(:messages_per_thread) { 50 }

    def log_from_threads
      threads = thread_count.times.map do |t|
        Thread.new do
          messages_per_thread.times do |m|
            described_class.info("thread-#{t}-message-#{m}", thread: t, seq: m)
          end
        end
      end
      threads.each(&:join)

      [].tap { |collected| collected << lines.pop until lines.empty? }
    end

    it "does not interleave text log lines across threads" do
      Busybee.log_format = :text
      collected = log_from_threads

      expect(collected.size).to eq(thread_count * messages_per_thread)
      expect(collected).to all match(/\A\[busybee\] thread-\d+-message-\d+ \(thread: \d+, seq: \d+\)\z/)
    end

    it "does not interleave JSON log lines across threads" do
      Busybee.log_format = :json
      collected = log_from_threads

      expect(collected.size).to eq(thread_count * messages_per_thread)
      expect(collected).to all satisfy("be valid JSON with expected keys") { |line|
        json = JSON.parse(line)
        json.key?("message") && json.key?("level") && json.key?("thread") && json.key?("seq")
      }
    end
  end
end
