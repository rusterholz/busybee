# frozen_string_literal: true

require "rspec/expectations"

module Busybee
  module Testing
    module Matchers
      extend RSpec::Matchers::DSL

      # Expected values compare as in RSpec's include: a Regexp or any matcher works.
      matcher :have_received_variables do |expected|
        match do |job|
          @actual = job.variables
          values_match?(a_hash_including(expected.transform_keys(&:to_s)), @actual)
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
