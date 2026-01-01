# frozen_string_literal: true

# Only load Rails environment when explicitly testing Railtie
return unless ENV["TEST_RAILS_INTEGRATION"]

ENV["RAILS_ENV"] = "test"
require File.expand_path("../dummy/config/environment", __dir__)
