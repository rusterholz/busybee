# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "appraisal", "~> 2.5"
gem "bundler", "~> 2.7"
gem "grpc-tools", "~> 1.76"
# Fix for OpenSSL 3.6.0 CRL verification bug on macOS
# See: https://github.com/ruby/openssl/issues/949
gem "openssl", ">= 3.2.2"
# parallel 2.x requires Ruby >= 3.3; pin to 1.x to keep Ruby 3.2 (our floor) in the matrix.
gem "parallel", "< 2.0"
gem "pry-byebug", platforms: :mri
gem "rake", "~> 13.0"
gem "rspec", "~> 3.13"
gem "rubocop", "~> 1.80"
gem "rubocop-rake"
gem "rubocop-rspec"
gem "sqlite3"
gem "webmock", "~> 3.24"
