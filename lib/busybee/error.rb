# frozen_string_literal: true

module Busybee
  # Base class for all gem operation errors.
  # Never raised directly; exists for `rescue Busybee::Error`.
  Error = Class.new(StandardError)

  # Raised when Credentials.build cannot determine credential type from provided params.
  # This happens when params are provided but don't match any known credential type pattern,
  # and no explicit credential_type is configured.
  CannotDetectCredentials = Class.new(Error)

  # Raised when job variables or headers JSON cannot be parsed
  InvalidJobJson = Class.new(Error)

  # Raised when OAuth2 token endpoint returns invalid JSON
  InvalidOAuthResponse = Class.new(Error)

  # Raised when a Worker DSL declaration is invalid (conflicting options, bad values, etc.)
  InvalidWorkerDefinition = Class.new(Error)

  # Raised when required inputs are missing from job variables/headers
  MissingInput = Class.new(Error)

  # Raised when required outputs are missing from perform's return value
  MissingOutput = Class.new(Error)

  # Raised when attempting to complete, fail, or throw error on a job that has already been handled
  JobAlreadyHandled = Class.new(Error)

  # Raised when OAuth2 token refresh fails (HTTP error from token endpoint)
  OAuthTokenRefreshFailed = Class.new(Error)

  # Raised when attempting to iterate a stream that has been closed
  StreamAlreadyClosed = Class.new(Error)
end
