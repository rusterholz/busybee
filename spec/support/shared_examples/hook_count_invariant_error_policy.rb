# frozen_string_literal: true

# The hook-count invariance contract, pinned once per lifecycle: what a
# lifecycle does with an error — suppress it, raise it, escalate it, blame it on
# somebody — must not depend on whether anyone happened to register a hook.
#
# It used to. A safe chain assembled from zero hooks was the bare core with no
# policy wrapper at all, which made "is something listening?" a load-bearing
# input to error handling: an error a worker had declared fatal escalated to a
# graceful shutdown only when a hook was registered, and an error from the work
# was swallowed and blamed on the hooks only when one was.
#
# Host groups provide three methods:
#   exercise(&work)             — run one turn of this lifecycle, with `work` as
#                                 the thing the hooks wrap or observe
#   register_observer           — register one no-op hook of this lifecycle's noun
#   register_raising_observer   — register one hook of that noun that raises
RSpec.shared_examples "a hook-count-invariant error policy" do
  # Everything an observer could tell about how the error was handled: whether
  # it escaped and as what, and whether the operator was told a hook failed.
  def outcome_of
    lines = []
    allow(Busybee).to receive(:logger).and_return(InvarianceLogger.new(lines))
    escaped =
      begin
        yield
        :returned
      rescue StandardError => e
        [:raised, e.class]
      end
    [escaped, lines.grep(/Error in hooks/).any?]
  end

  it "handles an error from the work identically with and without a hook registered" do
    bare = outcome_of { exercise { raise "work boom" } }
    register_observer
    observed = outcome_of { exercise { raise "work boom" } }

    expect(observed).to eq(bare)
  end

  it "applies one policy to a hook's own error however many hooks are registered" do
    register_raising_observer
    alone = outcome_of { exercise { :work } }

    Busybee::Hooks.reset!
    register_raising_observer
    register_observer
    alongside = outcome_of { exercise { :work } }

    expect(alongside).to eq(alone)
  end
end

# Records every level, so an unexpected call surfaces instead of vanishing into
# a permissive double — the trap that once hid a warning firing on every job.
class InvarianceLogger
  def initialize(lines) = @lines = lines

  %i[debug info warn error fatal].each do |level|
    define_method(level) { |message| @lines << "#{level}: #{message}" }
  end
end
