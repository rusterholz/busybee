# frozen_string_literal: true

require_relative "../credentials"

module Busybee
  class Credentials
    # Insecure credentials for local development, docker-compose, and CI.
    # No TLS, no authentication.
    class Insecure < Credentials
      def channel_credentials
        :this_channel_is_insecure
      end
    end
  end
end
