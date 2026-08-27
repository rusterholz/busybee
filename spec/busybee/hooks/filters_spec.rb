# frozen_string_literal: true

require "busybee/hooks"
require "busybee/job/activation"
require "busybee/worker/configuration"

RSpec.describe Busybee::Hooks::Filters do
  after { Busybee::Hooks.reset! }

  let(:noop) { proc { |_| } }

  describe "spellings" do
    it "accepts either spelling of a name, whichever the carrier happens to hold" do
      expect { Busybee.after_perform(status: "failed", &noop) }.not_to raise_error
      expect { Busybee.after_perform(job_type: :charge_card, &noop) }.not_to raise_error
    end

    it "matches either spelling at fire time, so neither silently misses" do
      fired = []
      Busybee.after_perform(status: "failed") { fired << :string_spelling }
      Busybee.after_perform(status: :failed) { fired << :symbol_spelling }
      job = build_test_job(type: "test")
      job.fail!("boom")

      Busybee::Hooks.run(:after_perform, job)
      expect(fired).to eq(%i[string_spelling symbol_spelling])
    end
  end

  describe "values that cannot express a match" do
    it "rejects a value no matcher rule could ever use" do
      expect { Busybee.after_perform(job_type: Object.new, &noop) }.
        to raise_error(ArgumentError, /cannot express a match/)
    end

    it "names the key and what it accepts" do
      expect { Busybee.after_perform(buffered: "yes", &noop) }.
        to raise_error(ArgumentError, /buffered: accepts TrueClass, FalseClass or Proc/)
    end

    it "checks inside an array rather than only its outermost shape" do
      expect { Busybee.after_perform(job_type: ["ok", Object.new], &noop) }.
        to raise_error(ArgumentError, /cannot express a match/)
    end
  end

  describe "values outside a closed vocabulary" do
    it "rejects a near-miss on a gem-owned vocabulary" do
      expect { Busybee.after_perform(status: :completed, &noop) }.
        to raise_error(ArgumentError, /status: :completed can never match/)
    end

    it "rejects a bad element inside an array, even when a sibling element is good" do
      expect { Busybee.after_perform(status: %i[complete bogus], &noop) }.
        to raise_error(ArgumentError, /:bogus can never match/)
    end

    it "leaves open vocabularies alone — stop reasons are minted by the adopter" do
      expect { Busybee.on_worker_shutdown(reason: :rollover, &noop) }.not_to raise_error
      expect { Busybee.after_perform(job_type: "anything_at_all", &noop) }.not_to raise_error
    end

    it "accepts a Regexp against a closed vocabulary when some member matches" do
      expect { Busybee.after_perform(status: /fail/, &noop) }.not_to raise_error
    end

    it "rejects a Regexp that no member of a closed vocabulary can satisfy" do
      expect { Busybee.after_perform(status: /\Anever_a_status\z/, &noop) }.
        to raise_error(ArgumentError, /can never match/)
    end

    it "exempts Procs, which are the escape hatch and cannot be read statically" do
      expect { Busybee.after_perform(status: ->(s) { s == :completed }, &noop) }.not_to raise_error
    end
  end

  describe "values unreachable at a hook's own moment" do
    it "rejects a job status the carrier cannot hold yet" do
      expect { Busybee.before_perform(status: :complete, &noop) }.
        to raise_error(ArgumentError, /status is :ready when before_perform fires/)
    end

    it "rejects an outcome filter on an around-hook, whose filters are read at selection" do
      expect { Busybee.around_job_execution(status: :complete, &noop) }.
        to raise_error(ArgumentError, /can never match/)
      expect { Busybee.around_call(status: :succeeded, &noop) }.
        to raise_error(ArgumentError, /can never match/)
    end

    it "rejects a stop reason on the one worker moment that precedes every stop" do
      expect { Busybee.on_worker_started(reason: :crash, &noop) }.
        to raise_error(ArgumentError, /reason is nil when on_worker_started fires/)
    end

    it "still accepts the same filter at a moment that can hold it" do
      expect { Busybee.after_perform(status: :complete, &noop) }.not_to raise_error
      expect { Busybee.after_call(status: :succeeded, &noop) }.not_to raise_error
      expect { Busybee.on_worker_shutdown(reason: :crash, &noop) }.not_to raise_error
    end
  end

  describe "the error: filter under moment narrowing" do
    it "rejects an error matcher where no error can have happened yet" do
      expect { Busybee.before_perform(error: RuntimeError, &noop) }.
        to raise_error(ArgumentError, /can never match/)
    end

    it "still accepts error: false there — 'no error' is exactly what is true" do
      expect { Busybee.before_perform(error: false, &noop) }.not_to raise_error
    end

    it "keeps its own matcher table for shapes the generic domains would allow" do
      expect { Busybee.after_perform(error: :not_a_matcher, &noop) }.
        to raise_error(ArgumentError, /error: accepts/)
    end
  end

  describe "the rpc vocabulary" do
    it "is the set busybee itself issues, not every RPC the gateway declares" do
      expect { Busybee.after_call(rpc: :complete_job, &noop) }.not_to raise_error
      expect { Busybee.after_call(rpc: :evaluate_decision, &noop) }.
        to raise_error(ArgumentError, /can never match/)
    end

    it "names only RPCs the gateway really declares" do
      gateway = Busybee::GRPC::Gateway::Service.rpc_descs.keys.map { |name| name.to_s.underscore.to_sym }
      expect(described_class::RPCS - gateway).to be_empty
    end
  end

  describe "vocabularies agree with the authorities they mirror" do
    it "mirrors the job sources Activation validates" do
      expect(described_class::JOB_SOURCES).to match_array(Busybee::Job::Activation::VALID_SOURCES)
    end

    it "mirrors the worker modes Configuration validates" do
      expect(described_class::WORKER_MODES).
        to match_array(Busybee::Worker::Configuration::VALID_WORKER_MODES)
    end

    it "covers every status a wrapped gRPC error can report" do
      reported = grpc_bad_status_classes.map do |klass|
        Busybee::GRPC::Error.wrap(klass.new("boom")).grpc_status
      end

      expect(described_class::GRPC_STATUSES).to include(*reported)
    end

    it "covers every status a job can actually reach, and names no others" do
      observed = %i[ready complete failed error].map { |status| job_reaching(status).status }
      expect(observed).to match_array(described_class::JOB_STATUSES)
    end
  end

  describe "the moment table describes what really happens" do
    # The worker-noun narrowings are read off the runner instead: on_worker_started
    # fires at runner.rb:144 with a status whose reason comes from @stop_reason,
    # which stop! is the only thing that sets.
    it "shows the perform-like moments only a ready job that has not errored" do
      seen = []
      Busybee.before_perform { |job| seen << [job.status, job.error] }
      Busybee.around_perform do |job, perform|
        seen << [job.status, job.error]
        perform.call
      end
      execute_worker(observing_worker)

      expect(seen).to eq([[:ready, nil], [:ready, nil]])
      expect(seen.map(&:first)).to all(be_one_of(narrowing(:before_perform, :status)))
    end

    it "shows before_call a pending carrier with no gRPC status and no error" do
      seen = []
      Busybee.before_call { |call| seen << [call.status, call.grpc_status, call.error] }
      Busybee::Client::Call.with_hooks(:complete_job) { |_call| :done }

      expect(seen).to eq([[:pending, nil, nil]])
      expect(seen.map(&:first)).to all(be_one_of(narrowing(:before_call, :status)))
    end

    it "shows after_call only the two resolved statuses" do
      seen = []
      Busybee.after_call { |call| seen << call.status }
      Busybee::Client::Call.with_hooks(:complete_job) { |_call| :done }
      suppress(RuntimeError) { Busybee::Client::Call.with_hooks(:complete_job) { raise "boom" } }

      expect(seen).to match_array(narrowing(:after_call, :status))
    end
  end

  describe "the moment table" do
    it "narrows only real hook types" do
      expect(described_class::MOMENTS.keys - Busybee::Hooks::HOOK_TYPES).to be_empty
    end

    it "narrows only keys that noun actually filters on" do
      described_class::MOMENTS.each do |type, narrowings|
        allowed = Busybee::Hooks::FILTER_KEYS.fetch(Busybee::Hooks::HOOK_NOUN.fetch(type))
        expect(narrowings.keys - allowed).to be_empty, "#{type} narrows a key it does not filter on"
      end
    end
  end

  # RSpec's be_in needs Object#in?; these carriers hold bare Symbols.
  def be_one_of(values) = satisfy { |value| values.include?(value) }

  def narrowing(type, key) = described_class::MOMENTS.fetch(type).fetch(key)

  def observing_worker
    Class.new(Busybee::Worker) do
      job_type "observed"
      def perform = nil
    end
  end

  def suppress(error_class)
    yield
  rescue error_class
    nil
  end

  def grpc_bad_status_classes
    GRPC.constants.filter_map do |name|
      const = GRPC.const_get(name)
      const if const.is_a?(Class) && const < GRPC::BadStatus && const != GRPC::Ok
    end
  end

  def job_reaching(status)
    job = build_test_job(type: "test")
    case status
    when :complete then job.complete!
    when :failed then job.fail!("boom")
    when :error then job.throw_bpmn_error!("CODE")
    end
    job
  end
end
