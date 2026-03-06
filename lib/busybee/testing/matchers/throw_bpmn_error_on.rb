# frozen_string_literal: true

require "rspec/expectations"

# Asserts that a worker throws a BPMN error on the job.
#
# Captures the error code and message passed to the stub client's
# +throw_bpmn_error+ call for optional verification via +with_code+.
#
# @example Basic usage
#   job = build_test_job(variables: { order_id: 999 })
#   expect(MyWorker).to throw_bpmn_error_on(job)
#
# @example With error code
#   expect(MyWorker).to throw_bpmn_error_on(job).with_code(:not_found)
#
# @example With error code and message
#   expect(MyWorker).to throw_bpmn_error_on(job).with_code(:not_found, message: /missing/)
#
RSpec::Matchers.define :throw_bpmn_error_on do |job|
  match do |worker_class|
    client = job.instance_variable_get(:@client)
    allow(client).to receive(:throw_bpmn_error) do |_key, code, message:|
      @actual_code = code
      @actual_message = message
    end

    execute_worker(worker_class, job: job)
    return false unless job.error?

    code_matches? && message_matches?
  rescue StandardError => e
    @raised_error = e
    false
  end

  chain :with_code do |expected_code, opts = {}|
    @expected_code = case expected_code
                     when Symbol then expected_code.to_s.upcase
                     when Class then expected_code.name.gsub("::", "_").underscore.upcase
                     else expected_code
                     end
    @expected_message = opts[:message]
  end

  def code_matches?
    return true unless @expected_code

    values_match?(@expected_code, @actual_code)
  end

  def message_matches?
    return true unless @expected_message

    values_match?(@expected_message, @actual_message)
  end

  failure_message do
    if @raised_error
      "expected #{actual} to throw a BPMN error, but it raised " \
        "#{@raised_error.class}: #{@raised_error.message}"
    elsif !job.error?
      "expected job to be error, but was #{job.status}"
    elsif @expected_code && !code_matches?
      "expected BPMN error code #{@expected_code.inspect}, " \
        "got #{@actual_code.inspect}"
    else
      "expected BPMN error message #{@expected_message.inspect}, " \
        "got #{@actual_message.inspect}"
    end
  end
end
