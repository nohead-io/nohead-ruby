# frozen_string_literal: true

require_relative "lib/nohead/version"

Gem::Specification.new do |spec|
  spec.name = "nohead"
  spec.version = Nohead::VERSION
  spec.authors = ["Nohead"]
  spec.email = ["hello@nohead.io"]
  spec.summary = "Official Ruby SDK for the Nohead API"
  spec.description = "A client for the Nohead API: records, collections, fields, assets, " \
                     "webhooks and search, with pagination, safe retries, uploads and " \
                     "webhook verification. No runtime dependencies."
  spec.homepage = "https://nohead.io"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => "https://github.com/nohead-io/nohead-ruby",
    "changelog_uri" => "https://github.com/nohead-io/nohead-ruby/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/nohead-io/nohead-ruby/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE"]
  spec.require_paths = ["lib"]
end
