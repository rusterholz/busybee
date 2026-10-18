# frozen_string_literal: true

require "date"

require "busybee/client/call"
require "busybee/grpc"
require "busybee/grpc/error"
require "busybee/hooks"
require "busybee/worker"

RSpec.describe Busybee::Hooks::Filters do
  around { |example| isolate_busybee_hooks { example.run } }

  let(:noop) { proc { |_| } }

  describe ".match?" do
    it "matches exact symbol" do
      expect(described_class.match?(:failed, :failed)).to be true
      expect(described_class.match?(:failed, :complete)).to be false
    end

    it "matches exact string" do
      expect(described_class.match?("process_order", "process_order")).to be true
      expect(described_class.match?("process_order", "other")).to be false
    end

    it "matches regex" do
      expect(described_class.match?(/order/, "process_order")).to be true
      expect(described_class.match?(/order/, "send_email")).to be false
    end

    it "treats String and Symbol filters as interchangeable, in both directions" do
      expect(described_class.match?("failed", :failed)).to be true
      expect(described_class.match?(:charge_card, "charge_card")).to be true
      expect(described_class.match?("failed", :complete)).to be false
      expect(described_class.match?(:charge_card, "ship_order")).to be false
    end

    it "matches a Class by a name given as a Symbol" do
      klass = Class.new { def self.name = "OrderWorker" }
      expect(described_class.match?(:OrderWorker, klass)).to be true
      expect(described_class.match?(:ShipmentWorker, klass)).to be false
    end

    it "does not cross the String/Symbol seam for values that merely stringify alike" do
      expect(described_class.match?("5", 5)).to be false
      expect(described_class.match?(:"1970-01-01", Date.new(1970, 1, 1))).to be false
    end

    it "matches Class via is_a? (case equality)" do
      expect(described_class.match?(RuntimeError, RuntimeError.new("boom"))).to be true
      expect(described_class.match?(RuntimeError, StandardError.new("boom"))).to be false
    end

    it "matches Class by identity (filter and value are the same Class)" do
      klass = Class.new { def self.name = "OrderWorker" }
      other = Class.new { def self.name = "ShipmentWorker" }
      expect(described_class.match?(klass, klass)).to be true
      expect(described_class.match?(klass, other)).to be false
    end

    it "matches Proc/Lambda" do
      filter = ->(v) { v.start_with?("order") }
      expect(described_class.match?(filter, "order_123")).to be true
      expect(described_class.match?(filter, "shipment_456")).to be false
    end

    it "falls back to Class name when value is a Class" do
      # Two distinct anonymous classes; DuplicateMethods misreads both as ::Object.name.
      # rubocop:disable Lint/DuplicateMethods
      expect(described_class.match?(/Order/, Class.new { def self.name = "OrderWorker" })).to be true
      expect(described_class.match?(/Order/, Class.new { def self.name = "ShipmentWorker" })).to be false
      # rubocop:enable Lint/DuplicateMethods
    end

    it "matches Class by exact name string (useful for load-order issues)" do
      klass = Class.new { def self.name = "OrderWorker" }
      expect(described_class.match?("OrderWorker", klass)).to be true
      expect(described_class.match?("ShipmentWorker", klass)).to be false
    end

    it "does not use name fallback for non-Class values" do
      expect(described_class.match?(/boom/, RuntimeError.new("boom"))).to be false
    end

    it "matches any element when the filter is an array" do
      expect(described_class.match?(%i[failed error], :error)).to be true
      expect(described_class.match?(%i[failed error], :complete)).to be false
    end

    it "applies each element matcher (string, regex, class name) inside an array" do
      expect(described_class.match?(["create_shipment", /assign/], "assign_driver")).to be true
      expect(described_class.match?(["create_shipment", /assign/], "load_warehouses")).to be false
    end

    it "treats an empty array as matching nothing" do
      expect(described_class.match?([], :anything)).to be false
    end
  end

  describe ".matches?" do
    # Targets are Job-like objects whose attribute names are looked up via
    # public_send. Struct stand-ins keep the matching tests focused on the
    # matching logic without Job construction overhead.
    let(:target_class) { Struct.new(:status, :job_type, keyword_init: true) }

    it "returns true when all filters match" do
      hook = { filters: { status: :failed, job_type: /order/ } }
      target = target_class.new(status: :failed, job_type: "process_order")
      expect(described_class.matches?(hook, target)).to be true
    end

    it "returns false when any filter does not match" do
      hook = { filters: { status: :failed, job_type: /order/ } }
      target = target_class.new(status: :complete, job_type: "process_order")
      expect(described_class.matches?(hook, target)).to be false
    end

    it "returns true (vacuous truth) when filters are empty" do
      hook = { filters: {} }
      target = target_class.new(status: :ready, job_type: nil)
      expect(described_class.matches?(hook, target)).to be true
    end
  end

  describe ".error_match?" do
    let(:boom) { RuntimeError.new("boom") }

    it "matches the absence of an error with false" do
      expect(described_class.error_match?(false, nil)).to be true
      expect(described_class.error_match?(false, boom)).to be false
    end

    it "matches the presence of any error with true" do
      expect(described_class.error_match?(true, boom)).to be true
      expect(described_class.error_match?(true, nil)).to be false
    end

    it "matches by exact class" do
      expect(described_class.error_match?(RuntimeError, boom)).to be true
      expect(described_class.error_match?(ArgumentError, boom)).to be false
    end

    it "matches by superclass (hierarchy, like rescue)" do
      expect(described_class.error_match?(StandardError, boom)).to be true
    end

    it "matches by mixin module on the error's class" do
      reportable = Module.new
      tagged = Class.new(StandardError) { include reportable }.new("tagged")
      expect(described_class.error_match?(reportable, tagged)).to be true
      expect(described_class.error_match?(reportable, boom)).to be false
    end

    it "matches a String against the error's own class name, never its ancestry" do
      expect(described_class.error_match?("RuntimeError", boom)).to be true
      expect(described_class.error_match?("StandardError", boom)).to be false
    end

    it "matches a Regexp against the error's own class name, never its ancestry" do
      expect(described_class.error_match?(/Runtime/, boom)).to be true
      expect(described_class.error_match?(/StandardError/, boom)).to be false
    end

    it "matches with a Proc receiving the error itself" do
      expect(described_class.error_match?(->(e) { e.message == "boom" }, boom)).to be true
      expect(described_class.error_match?(->(e) { e.message == "quiet" }, boom)).to be false
    end

    it "matches any element of an Array, mixing matcher kinds" do
      expect(described_class.error_match?([ArgumentError, /Runtime/], boom)).to be true
      expect(described_class.error_match?([ArgumentError, /Type/], boom)).to be false
    end

    it "matches nothing but false when no error is present (Procs are not even called)" do
      probe = ->(_) { raise "must not be called on nil" }
      aggregate_failures do
        expect(described_class.error_match?(true, nil)).to be false
        expect(described_class.error_match?(StandardError, nil)).to be false
        expect(described_class.error_match?("RuntimeError", nil)).to be false
        expect(described_class.error_match?(/anything/, nil)).to be false
        expect(described_class.error_match?(probe, nil)).to be false
        expect(described_class.error_match?([probe, true], nil)).to be false
      end
    end
  end

  describe ".matches? with the error: key" do
    let(:target_class) { Struct.new(:error, keyword_init: true) }

    it "routes error: through the bespoke matcher, so a Regexp sees the class name" do
      # Under the generic layers this was the silent-no-match trap: a Regexp
      # never === an exception instance, and the name fallback needs a Class.
      hook = { filters: { error: /Runtime/ } }
      expect(described_class.matches?(hook, target_class.new(error: RuntimeError.new("boom")))).to be true
      expect(described_class.matches?(hook, target_class.new(error: nil))).to be false
    end

    it "expresses \"did not error\" with error: false" do
      hook = { filters: { error: false } }
      expect(described_class.matches?(hook, target_class.new(error: nil))).to be true
      expect(described_class.matches?(hook, target_class.new(error: RuntimeError.new("boom")))).to be false
    end
  end

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

  describe "the published scope table" do
    it "accounts for every hook type" do
      missing = Busybee::Hooks::HOOK_TYPES.reject { |type| scope_table_row(type) }
      expect(missing).to be_empty, "hooks.md's scope table does not mention #{missing.join(', ')}"
    end

    it "states the same narrowings the code enforces" do
      described_class::MOMENTS.each do |type, narrowings|
        row = scope_table_row(type)
        narrowings.each_value do |values|
          values.compact.each do |value|
            expect(row).to include(value.inspect), "hooks.md's row for #{type} omits #{value.inspect}"
          end
        end
      end
    end
  end

  describe "the moment table" do
    it "narrows only real hook types" do
      expect(described_class::MOMENTS.keys - Busybee::Hooks::HOOK_TYPES).to be_empty
    end

    it "narrows only keys that noun actually filters on" do
      described_class::MOMENTS.each do |type, narrowings|
        allowed = described_class::FILTERS.fetch(Busybee::Hooks::HOOK_NOUN.fetch(type)).keys
        expect(narrowings.keys - allowed).to be_empty, "#{type} narrows a key it does not filter on"
      end
    end
  end

  # The scope table in hooks.md is the reader-facing face of MOMENTS; these read it
  # back so the prose and the enforcement cannot drift apart.
  def scope_table_row(type)
    scope_table.find { |row| row.include?("`#{type}`") }
  end

  def scope_table
    section = hooks_doc[/^### Filter Scope by Moment$(.*?)^### /m, 1]
    section.lines.select { |line| line.start_with?("| `") }
  end

  def hooks_doc
    @hooks_doc ||= File.read(File.expand_path("../../../docs/hooks.md", __dir__))
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
