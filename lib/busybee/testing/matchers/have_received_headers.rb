# frozen_string_literal: true

require "rspec/expectations"

RSpec::Matchers.define :have_received_headers do |expected|
  match do |job|
    expected_stringified = expected.transform_keys(&:to_s)
    @actual = job.headers
    @actual.slice(*expected_stringified.keys) == expected_stringified
  end

  failure_message do
    "expected job headers to include #{expected.inspect}\n" \
      "actual headers: #{@actual.inspect}"
  end

  failure_message_when_negated do
    "expected job headers not to include #{expected.inspect}\n" \
      "actual headers: #{@actual.inspect}"
  end
end
