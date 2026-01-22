# frozen_string_literal: true

module Busybee
  # Base class for all gem operation errors.
  # Never raised directly; exists for `rescue Busybee::Error`.
  class Error < StandardError
  end

  # Raised when OAuth2 token refresh fails (HTTP error from token endpoint)
  OAuthTokenRefreshFailed = Class.new(Error)

  # Raised when OAuth2 token endpoint returns invalid JSON
  InvalidOAuthResponse = Class.new(Error)

  # Raised when job variables or headers JSON cannot be parsed
  InvalidJobJson = Class.new(Error)

  # Raised when attempting to complete, fail, or throw error on a job that has already been handled
  JobAlreadyHandled = Class.new(Error)
end
