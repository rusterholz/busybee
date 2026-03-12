# frozen_string_literal: true

# Test worker classes for CLI integration tests.
#
# These are loaded by the test harness subprocess — NOT by the main test suite.
# They must be real named constants so the CLI can resolve them via Kernel.const_get.

require "busybee"

# Single-job worker matching job_process.bpmn's "process-order" service task.
class CLITestWorker < Busybee::Worker
  job_type "process-order"
  polling request_timeout: 1_000

  def perform
    signal_job_processed!
  end

  private

  # Write the job key to a signal file so the test process can detect completion.
  def signal_job_processed!
    path = ENV.fetch("BUSYBEE_TEST_SIGNAL_FILE", nil)
    return unless path

    File.open(path, "a") do |f|
      f.flock(File::LOCK_EX)
      f.puts(job.key)
    end
  end
end

# Worker A for multi_job_process.bpmn's parallel "job-type-a" task.
class CLITestWorkerA < Busybee::Worker
  job_type "job-type-a"
  worker_mode :polling
  polling request_timeout: 1_000

  def perform
    path = ENV.fetch("BUSYBEE_TEST_SIGNAL_FILE", nil)
    return unless path

    File.open(path, "a") do |f|
      f.flock(File::LOCK_EX)
      f.puts("a:#{job.key}")
    end
  end
end

# Worker B for multi_job_process.bpmn's parallel "job-type-b" task.
class CLITestWorkerB < Busybee::Worker
  job_type "job-type-b"
  worker_mode :streaming

  def perform
    path = ENV.fetch("BUSYBEE_TEST_SIGNAL_FILE", nil)
    return unless path

    File.open(path, "a") do |f|
      f.flock(File::LOCK_EX)
      f.puts("b:#{job.key}")
    end
  end
end
