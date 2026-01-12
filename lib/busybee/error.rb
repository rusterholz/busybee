# frozen_string_literal: true

module Busybee
  # Base class for all gem operation errors.
  # Never raised directly; exists for `rescue Busybee::Error`.
  class Error < StandardError
  end

  # Raised when OAuth2 token refresh fails (HTTP error from token endpoint)
  OAuthTokenRefreshFailed = Class.new(Error)

  # Raised when OAuth2 token endpoint returns invalid JSON
  OAuthInvalidResponse = Class.new(Error)
end
