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
end
