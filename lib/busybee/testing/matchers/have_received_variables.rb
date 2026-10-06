# frozen_string_literal: true

require "rspec/expectations"

module Busybee
  module Testing
    module Matchers
      extend RSpec::Matchers::DSL

      matcher :have_received_variables do |expected|
        match do |job|
          expected_stringified = expected.transform_keys(&:to_s)
          @actual = job.variables
          @actual.slice(*expected_stringified.keys) == expected_stringified
        end

        failure_message do
          "expected job variables to include #{expected.inspect}\n" \
            "actual variables: #{@actual.inspect}"
        end

        failure_message_when_negated do
          "expected job variables not to include #{expected.inspect}\n" \
            "actual variables: #{@actual.inspect}"
        end
      end
    end
  end
end
