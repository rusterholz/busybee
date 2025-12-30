# frozen_string_literal: true

require_relative "lib/busybee/version"

Gem::Specification.new do |spec|
  spec.name          = "busybee"
  spec.version       = Busybee::VERSION
  spec.authors       = ["Andy Rusterholz"]
  spec.email         = ["andyrusterholz@gmail.com"]

  spec.summary       = "A complete Ruby toolkit for BPMN workflow orchestration."
  spec.description = <<~DESC.gsub(/\s+/, " ").strip
    The missing Ruby gem for Camunda 8. Production-ready worker framework
    that runs out of the box - define your job handlers and go. Idiomatic
    Zeebe client with sensible defaults and configuration where you want it.
    RSpec testing helpers and CI/CD deployment tooling for BPMNs.
  DESC
  spec.homepage      = "https://github.com/rusterholz/busybee"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  # allowed_push_host removed — this is a public gem, rubygems.org is the default
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/rusterholz/busybee"
  spec.metadata["changelog_uri"] = "https://github.com/rusterholz/busybee/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Explicit file list - audit before each release (see docs/development.md)
  spec.files = Dir.glob(
    %w[lib/**/* docs/**/* LICENSE.txt README.md CHANGELOG.md]
  ).reject { |f| f.include?("docs/internal.md") || f.include?("docs/development.md") }
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Dev dependencies are listed in the Gemfile.

  # Runtime dependencies
  spec.add_dependency "base64"
  spec.add_dependency "grpc", "~> 1.76"
end
