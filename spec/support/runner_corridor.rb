# frozen_string_literal: true

require "concurrent"

# Driving a real runner to its end from a spec, for the :gateway corridor specs.
module RunnerCorridor
  # Gives the runner its own thread and waits for it, rather than wrapping the
  # call in Timeout.timeout: a hang should fail the example loudly, not inject an
  # asynchronous exception at an arbitrary point inside grpc's internals. Returns
  # the error the runner raised, whatever its class, or nil if it exited cleanly.
  def run_to_completion(seconds: 15)
    raised = nil
    thread = Thread.new do
      runner.run!
    rescue Exception => e # rubocop:disable Lint/RescueException
      raised = e
    end
    return raised if thread.join(seconds)

    begin
      runner.kill!
    rescue NoMemoryError => e
      # RSpec never rescues one, so a hook's simulated NoMemoryError would end the whole run
      raise "the runner did not finish within #{seconds}s, and its kill raised #{e.class}"
    end
    raise "the runner did not finish within #{seconds}s"
  end

  # on_worker_shutdown is the public window onto a runner's final counters, and
  # it fires on every exit path. Multi's children fire it from their own
  # threads, hence the concurrent collection.
  def shutdown_statuses_from
    captured = Concurrent::Array.new
    Busybee.on_worker_shutdown { |status| captured << status }
    yield
    captured
  end

  def shutdown_status_from(&) = shutdown_statuses_from(&).first

  # shutdown_wait_timeout is process-wide, so an example sets it on Busybee and
  # puts it back.
  def with_shutdown_wait_timeout(milliseconds)
    saved = Busybee.instance_variable_get(:@shutdown_wait_timeout)
    Busybee.instance_variable_set(:@shutdown_wait_timeout, milliseconds)
    yield
  ensure
    Busybee.instance_variable_set(:@shutdown_wait_timeout, saved)
  end

  # A job's activation and closing hooks, in firing order, keyed by job.
  def record_job_brackets
    Concurrent::Array.new.tap do |brackets|
      Busybee.on_job_activated { |job| brackets << [:activated, job.key] }
      Busybee.on_job_executed { |job| brackets << [:executed, job.key] }
      Busybee.on_job_not_executed { |job| brackets << [:not_executed, job.key] }
    end
  end
end

RSpec.configure do |config|
  config.include RunnerCorridor, :gateway
end
