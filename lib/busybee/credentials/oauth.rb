# frozen_string_literal: true

require "active_support"
require "active_support/cache"
require "grpc"
require "json"
require "net/http"

require "busybee/credentials"
require "busybee/error"

module Busybee
  class Credentials
    # OAuth2 credentials with automatic token refresh.
    # Combines TLS channel credentials with OAuth2 call credentials.
    #
    # Token caching uses ActiveSupport::Cache with race_condition_ttl to prevent
    # thundering herd during refresh - multiple threads won't block waiting for
    # a refresh when the token is still valid.
    #
    # @example Basic usage
    #   credentials = Busybee::Credentials::OAuth.new(
    #     token_url: "https://auth.example.com/oauth/token",
    #     client_id: "my-client-id",
    #     client_secret: "my-client-secret",
    #     audience: "zeebe-api",
    #     cluster_address: "zeebe.example.com:443"
    #   )
    #   stub = credentials.grpc_stub
    #
    # @example With custom CA certificate
    #   credentials = Busybee::Credentials::OAuth.new(
    #     token_url: "https://auth.example.com/oauth/token",
    #     client_id: "my-client-id",
    #     client_secret: "my-client-secret",
    #     audience: "zeebe-api",
    #     cluster_address: "zeebe.example.com:443",
    #     certificate_file: "/path/to/ca-cert.pem"
    #   )
    #
    class OAuth < Credentials
      # These constants may become configuration options in a future version.
      RACE_CONDITION_TTL_SECONDS = 30
      TOKEN_CACHE_SIZE_BYTES = 4 * 1024 * 1024 # 4MB

      # @param token_url [String] OAuth2 token endpoint URL
      # @param client_id [String] OAuth2 client ID
      # @param client_secret [String] OAuth2 client secret
      # @param audience [String] OAuth2 audience (API identifier)
      # @param scope [String, nil] Optional OAuth2 scope for API access control
      # @param cluster_address [String, nil] Zeebe cluster address (host:port)
      # @param certificate_file [String, nil] Optional CA certificate file path
      def initialize( # rubocop:disable Metrics/ParameterLists
        token_url:,
        client_id:,
        client_secret:,
        audience:,
        scope: nil,
        cluster_address: nil,
        certificate_file: nil
      )
        super(cluster_address: cluster_address)
        @token_uri = URI(token_url)
        @client_id = client_id
        @client_secret = client_secret
        @audience = audience
        @scope = scope
        @certificate_file = certificate_file
      end

      def grpc_channel_credentials
        build_tls_credentials.compose(grpc_call_credentials)
      end

      private

      def grpc_call_credentials
        ::GRPC::Core::CallCredentials.new(method(:token_updater).to_proc)
      end

      def build_tls_credentials
        if @certificate_file
          ::GRPC::Core::ChannelCredentials.new(File.read(@certificate_file))
        else
          ::GRPC::Core::ChannelCredentials.new
        end
      end

      def current_token
        # Use race_condition_ttl to prevent thundering herd:
        # - When token is fresh, multiple threads read from cache
        # - 30s before expiry, first thread refreshes while others use stale token
        token_cache.fetch(cache_key, race_condition_ttl: RACE_CONDITION_TTL_SECONDS) do |_key, options = nil|
          token_data = fetch_token_response

          # Set cache expiry dynamically if possible (Rails 7.1+ only):
          if options&.respond_to?(:expires_in=) # rubocop:disable Lint/RedundantSafeNavigation
            options.expires_in = token_data.fetch("expires_in", 3600).to_i - RACE_CONDITION_TTL_SECONDS
          end

          token_data["access_token"]
        end
      end

      def fetch_token_response
        response = http_client.request(build_token_request)
        unless response.is_a?(Net::HTTPSuccess)
          raise Busybee::OAuthTokenRefreshFailed, "HTTP #{response.code}: #{response.body}"
        end

        JSON.parse(response.body)
      rescue JSON::ParserError => e
        raise Busybee::OAuthInvalidResponse, "Invalid JSON response from token endpoint: #{e.message}"
      end

      def http_client
        Net::HTTP.new(@token_uri.host, @token_uri.port).tap do |client|
          client.use_ssl = (@token_uri.scheme == "https")
        end
      end

      def build_token_request
        Net::HTTP::Post.new(@token_uri.path).tap do |request|
          form_data = {
            "grant_type" => "client_credentials",
            "client_id" => @client_id,
            "client_secret" => @client_secret,
            "audience" => @audience
          }
          form_data["scope"] = @scope if @scope
          request.set_form_data(form_data)
        end
      end

      def token_updater(_context)
        { authorization: "Bearer #{current_token}" }
      end

      def cache_key
        @cache_key ||= "busybee:oauth_token:#{@audience}:#{@client_id}"
      end

      def token_cache
        @token_cache ||= ActiveSupport::Cache::MemoryStore.new(size: TOKEN_CACHE_SIZE_BYTES)
      end
    end
  end
end
