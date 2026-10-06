# frozen_string_literal: true

require "rspec/expectations"

module Busybee
  module Testing
    module Matchers
      extend RSpec::Matchers::DSL

      # Expected values compare as in RSpec's include: a Regexp or any matcher works.
      matcher :have_received_headers do |expected|
        match do |job|
          @actual = job.headers
          values_match?(a_hash_including(expected.transform_keys(&:to_s)), @actual)
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
    end
  end
end
