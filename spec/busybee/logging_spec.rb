# frozen_string_literal: true

require "concurrent"
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
    # ISO8601 UTC with millisecond precision — the time field's wire shape.
    let(:time_rx) { /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/ }

    let(:logger) do
      Logger.new(log_output).tap do |l|
        l.formatter = proc { |_severity, _datetime, _progname, msg| "#{msg}\n" }
      end
    end

    before { Busybee.log_format = :json }

    it "stamps each line with the current UTC time" do
      described_class.info("stamped")
      json = JSON.parse(log_output.string)
      expect(Time.iso8601(json.fetch("time"))).to be_within(5).of(Time.now.utc)
    end

    describe ".info" do
      it "logs as JSON with message, level, and context" do
        described_class.info("test message", job_key: 123)
        json = JSON.parse(log_output.string)
        expect(json).to match({
                                "message" => "[busybee] test message",
                                "level" => "info",
                                "job_key" => 123,
                                "time" => match(time_rx)
                              })
      end
    end

    describe ".warn" do
      it "logs as JSON with warn level" do
        described_class.warn("warning message")
        json = JSON.parse(log_output.string)
        expect(json).to match({
                                "message" => "[busybee] warning message",
                                "level" => "warn",
                                "time" => match(time_rx)
                              })
      end
    end

    describe ".error" do
      it "logs as JSON with error level" do
        described_class.error("error message", error_code: 500)
        json = JSON.parse(log_output.string)
        expect(json).to match({
                                "message" => "[busybee] error message",
                                "level" => "error",
                                "error_code" => 500,
                                "time" => match(time_rx)
                              })
      end
    end

    describe ".debug" do
      it "logs as JSON with debug level" do
        logger.level = Logger::DEBUG
        described_class.debug("debug message")
        json = JSON.parse(log_output.string)
        expect(json).to match({
                                "message" => "[busybee] debug message",
                                "level" => "debug",
                                "time" => match(time_rx)
                              })
      end
    end
  end

  # What a line says about the job, worker or call it concerns, and about an
  # error: everything in JSON, only what the call site wrote in text.
  describe "carriers, context and errors" do
    let(:logger) do
      Logger.new(log_output).tap do |l|
        l.formatter = proc { |_severity, _datetime, _progname, msg| "#{msg}\n" }
      end
    end
    let(:carrier) do
      Struct.new(:logging_context).new(
        { job_key: 1, status: "carrier's", error_class: "carrier's", message: "carrier's", level: "x", time: "y" }
      )
    end

    def raised(error)
      raise error
    rescue Exception => e # rubocop:disable Lint/RescueException
      e
    end

    def json_line = JSON.parse(log_output.string)

    context "when in json mode" do
      before { Busybee.log_format = :json }

      it "logs the carrier's logging_context with the message" do
        job = build_test_job(type: "frog_blast", key: 93_928_392_854)
        described_class.info("completed frog_blast job #93928392854", job)

        expect(json_line).to include(JSON.parse(job.logging_context.to_json)).
          and include("message" => "[busybee] completed frog_blast job #93928392854", "level" => "info")
      end

      it "layers explicit context over the carrier, the error over both, and its own fields over everything" do
        described_class.warn("the message", carrier, error: IOError.new("closed stream"), status: "explicit")

        expect(json_line).to include("job_key" => 1, "status" => "explicit", "error_class" => "IOError",
                                     "error_message" => "closed stream", "message" => "[busybee] the message",
                                     "level" => "warn", "time" => match(/\A\d{4}-/))
      end

      it "locates an ordinary error at its first backtrace frame" do
        error = raised(IOError.new("closed stream"))
        described_class.warn("failed", error: error)

        expect(json_line).to include("error_location" => error.backtrace.first)
      end

      it "doesn't locate an error the process can't recover from" do
        described_class.error("failed", error: raised(NoMemoryError.new("failed to allocate memory")))

        expect(json_line).to include("error_class" => "NoMemoryError").
          and(satisfy { |line| !line.key?("error_location") })
      end

      it "renders an exception value as its class and message" do
        exceptional = Struct.new(:logging_context).new({ cause: IOError.new("closed stream") })
        described_class.warn("failed", exceptional, other: RuntimeError.new("boom"))

        expect(json_line).to include("cause" => "[IOError] closed stream", "other" => "[RuntimeError] boom")
      end
    end

    context "when in text mode" do
      before { Busybee.log_format = :text }

      it "writes the message and explicit context, leaving the carrier and error to JSON" do
        described_class.warn("the message", carrier, error: IOError.new("closed stream"), status: "explicit")

        expect(log_output.string).to eq("[busybee] the message (status: \"explicit\")\n")
      end

      it "renders an exception value as its class and message" do
        described_class.warn("failed", cause: IOError.new("closed stream"))

        expect(log_output.string).to eq("[busybee] failed (cause: \"[IOError] closed stream\")\n")
      end
    end

    it "refuses a carrier that has no logging_context, saying so on stderr" do
      expect { described_class.info("the message", { job_key: 1 }) }.
        to output(/\A\[busybee\] failed to log \(ArgumentError: .*logging_context.*\): the message\n\z/).to_stderr
      expect(log_output.string).to be_empty
    end
  end

  # A log call returns nil and never raises, wherever it sits, a rescue clause
  # included: what goes wrong inside it is told to stderr, and an error the
  # process can't recover from raises the fire alarm on its way.
  describe "safety" do
    let(:failure) { IOError.new("closed stream") }
    let(:logger) do
      raising = failure
      Class.new { %i[debug info warn error].each { |level| define_method(level) { |_line| raise raising } } }.new
    end

    it "returns nil" do
      Busybee.logger = Logger.new(log_output)

      expect(described_class.info("logged")).to be_nil
    end

    it "returns nil when the logger fails, saying so on stderr" do
      result = :unset
      expect { result = described_class.warn("Failed to complete frog_blast job #93928392854") }.
        to output("[busybee] failed to log (IOError: closed stream): Failed to complete frog_blast job #93928392854\n").
        to_stderr
      expect(result).to be_nil
    end

    it "leaves the fire alarm down for an ordinary failure" do
      expect { described_class.warn("logged") }.to output(/failed to log/).to_stderr
      expect(Busybee::Runner.exit_immediately?).to be(false)
    end

    context "when the failure is one the process can't recover from" do
      let(:failure) { NoMemoryError.new("failed to allocate memory") }

      it "raises the fire alarm, then says so on stderr" do
        expect { described_class.error("logged") }.to output(/failed to log \(NoMemoryError/).to_stderr
        expect(Busybee::Runner.exit_immediately_reason).to eq(:crash)
      end
    end

    it "stays silent when stderr fails too" do
      allow($stderr).to receive(:write).and_raise(IOError, "stderr closed")

      expect(described_class.warn("logged")).to be_nil
    end

    it "contains a value that fails to render" do
      Busybee.logger = Logger.new(log_output)
      unrenderable = Object.new
      def unrenderable.inspect = raise(NotImplementedError, "no inspect for you")

      expect { described_class.info("logged", value: unrenderable) }.
        to output(/failed to log \(NotImplementedError: no inspect for you\): logged/).to_stderr
    end
  end

  # gRPC hands back status details tagged BINARY, and an error message can carry
  # any bytes at all; the line is written either way.
  describe "encodings" do
    let(:logger) do
      Logger.new(log_output).tap do |l|
        l.formatter = proc { |_severity, _datetime, _progname, msg| "#{msg}\n" }
      end
    end
    let(:valid_binary) { "café closed".b }
    let(:invalid) { "bad \xFF bytes".b }

    context "when in json mode" do
      before { Busybee.log_format = :json }

      it "reads valid UTF-8 tagged BINARY as UTF-8" do
        described_class.warn(valid_binary, details: valid_binary)

        expect(JSON.parse(log_output.string)).
          to include("message" => "[busybee] café closed", "details" => "café closed")
      end

      it "replaces bytes that aren't UTF-8" do
        described_class.warn(invalid, details: invalid, error: IOError.new(invalid))

        expect(JSON.parse(log_output.string)).to include("message" => "[busybee] bad � bytes",
                                                         "details" => "bad � bytes",
                                                         "error_message" => "bad � bytes")
      end
    end

    context "when in text mode" do
      before { Busybee.log_format = :text }

      it "replaces bytes that aren't UTF-8 in the message" do
        described_class.warn(invalid)

        expect(log_output.string).to eq("[busybee] bad � bytes\n")
      end
    end
  end

  context "when logger is nil" do
    let(:logger) { nil }

    it "does not raise error" do
      expect { described_class.info("test") }.not_to raise_error
    end
  end

  # A logger with no lock of its own (unlike stdlib Logger), writing a line a
  # character at a time and yielding the thread between characters. on_write
  # runs before each line, on the writing thread.
  describe "thread safety" do
    let(:trickling_logger_class) do
      Class.new do
        attr_reader :output
        attr_accessor :on_write

        def initialize = @output = +""

        %i[debug info warn error].each do |level|
          define_method(level) do |line|
            on_write&.call(line)
            "#{line}\n".each_char do |char|
              @output << char
              Thread.pass
            end
          end
        end
      end
    end
    let(:logger) { trickling_logger_class.new }
    let(:release) { Concurrent::Event.new }

    before { Busybee.log_format = :text }

    def wait_until(seconds = 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      sleep 0.001 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    end

    # Logs line on a thread of its own, holding that write open (and the lock
    # with it) until release is set; returns the thread once the write began.
    def hold_a_write(line)
      writing = Concurrent::Event.new
      held = release
      logger.on_write = lambda do |written|
        next unless written.include?(line)

        writing.set
        held.wait(5)
      end
      Thread.new { described_class.info(line) }.tap { writing.wait(5) }
    end

    # Logs line on a thread of its own and returns it once it waits its turn.
    def queue_a_write(line)
      thread = Thread.new do
        Thread.current.report_on_exception = false
        described_class.info(line)
      end
      wait_until { thread.status == "sleep" }
      thread
    end

    after { release.set }

    it "keeps concurrent lines whole on a logger with no lock of its own" do
      threads = Array.new(6) do |t|
        Thread.new { 30.times { |m| described_class.info("thread #{t} message #{m}", seq: m) } }
      end
      threads.each(&:join)

      lines = logger.output.lines
      aggregate_failures do
        expect(lines.size).to eq(180)
        expect(lines).to all match(/\A\[busybee\] thread \d message \d+ \(seq: \d+\)\n\z/)
      end
    end

    it "writes to the logger it was called with, though the logger is swapped while it waits its turn" do
      first = hold_a_write("first")
      second = queue_a_write("second")
      Busybee.logger = nil
      release.set

      expect { [first, second].each { |thread| thread.join(5) } }.not_to raise_error
      expect(logger.output.lines).to eq(["[busybee] first\n", "[busybee] second\n"])
    end

    it "logs from a value that logs while being rendered" do
      logging = described_class
      chatty = Object.new
      chatty.define_singleton_method(:inspect) { logging.info("rendering").then { "chatty" } }

      described_class.info("outer", value: chatty)

      expect(logger.output.lines).to eq(["[busybee] rendering\n", "[busybee] outer (value: chatty)\n"])
    end

    it "renders a line without holding up another thread's write" do
      logging = described_class
      other_written = Concurrent::Event.new
      slow = Object.new
      slow.define_singleton_method(:inspect) do
        Thread.new { logging.info("other").then { other_written.set } }
        other_written.wait(2) ? "slow" : "timed out"
      end

      described_class.info("rendered", value: slow)

      expect(logger.output.lines).to eq(["[busybee] other\n", "[busybee] rendered (value: slow)\n"])
    end

    it "logs from inside the logger's own write" do
      logging = described_class
      logger.on_write = ->(line) { logging.warn("inner") if line.include?("outer") }

      described_class.info("outer")

      expect(logger.output.lines).to contain_exactly("[busybee] outer\n", "[busybee] inner\n")
    end

    def trap_logging(line)
      raised = nil
      previous = trap("USR2") do
        described_class.info(line)
      rescue Exception => e # rubocop:disable Lint/RescueException
        raised = e
      end
      Process.kill("USR2", Process.pid)
      wait_until { logger.output.include?(line) || raised }
      trap("USR2", previous)
      raised
    end

    it "logs from a signal trap" do
      expect([trap_logging("trapped"), logger.output]).to eq([nil, "[busybee] trapped\n"])
    end

    it "logs from a signal trap while another thread is writing" do
      holder = hold_a_write("holder")
      raised = trap_logging("trapped")
      release.set
      holder.join(5)

      expect([raised, logger.output.lines]).to eq([nil, ["[busybee] trapped\n", "[busybee] holder\n"]])
    end

    it "leaves a thread waiting its turn able to be killed" do
      hold_a_write("stuck")
      waiting = queue_a_write("waiting")
      waiting.kill

      expect(waiting.join(1)).to eq(waiting)
    end
  end
end
