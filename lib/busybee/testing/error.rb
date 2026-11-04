# frozen_string_literal: true

module Busybee
  module Testing
    # Base class for the testing helpers' own errors.
    # Never raised directly; exists for `rescue Busybee::Testing::Error`.
    Error = Class.new(StandardError)

    # Errors below this point are specific and semantic -- they are used in just one or two
    # places, and their name tells you exactly what went wrong:

    # Raised when assert_process_completed! is called with no process instance to check
    NoCurrentProcessInstance = Class.new(Error)

    # Raised when the jobs asked for aren't available for activation
    NoJobsAvailable = Class.new(Error)
    NoJobAvailable = NoJobsAvailable

    # Raised when assert_process_completed! finds the process instance still running
    ProcessStillRunning = Class.new(Error)
  end
end
