# frozen_string_literal: true

module Busybee
  # Base class for all gem operation errors.
  # Never raised directly; exists for `rescue Busybee::Error`.
  Error = Class.new(StandardError)

  # Raised when OAuth2 token endpoint returns invalid JSON
  InvalidOAuthResponse = Class.new(Error)

  # Raised when job variables or headers JSON cannot be parsed
  InvalidJobJson = Class.new(Error)

  # Raised when attempting to complete, fail, or throw error on a job that has already been handled
  JobAlreadyHandled = Class.new(Error)

  # Raised when OAuth2 token refresh fails (HTTP error from token endpoint)
  OAuthTokenRefreshFailed = Class.new(Error)

  # Raised when attempting to iterate a stream that has been closed
  StreamAlreadyClosed = Class.new(Error)
end
