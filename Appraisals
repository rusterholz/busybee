# frozen_string_literal: true

# Axes: Rails version × concurrent-ruby version
# concurrent-ruby floor (1.1.x) and latest (1.3.x) are tested across compatible combos.
# Rails 7.2+ requires concurrent-ruby >= 1.3.1, so only 7.0/7.1 pair with the 1.1 floor.
# When adding/removing Rails versions, update the matrix in .github/workflows/ci.yml too.

CONCURRENT_RUBY_VERSIONS = {
  "concurrent-1.1" => "~> 1.1.7",
  "concurrent-1.3" => "~> 1.3.6"
}.freeze

# Rails versions grouped by concurrent-ruby compatibility
RAILS_COMPATIBLE_WITH_CR_1_0 = {
  "rails-7.0" => "~> 7.0.10",
  "rails-7.1" => "~> 7.1.6"
}.freeze

RAILS_REQUIRING_CR_1_3 = {
  "rails-7.2" => "~> 7.2.3",
  "rails-8.0" => "~> 8.0.4",
  "rails-8.1" => "~> 8.1.2"
}.freeze

ALL_RAILS = RAILS_COMPATIBLE_WITH_CR_1_0.merge(RAILS_REQUIRING_CR_1_3).freeze

# Base appraisals (no Rails) with each concurrent-ruby version
CONCURRENT_RUBY_VERSIONS.each do |cr_name, cr_version|
  appraise "base-#{cr_name}" do
    gem "concurrent-ruby", cr_version
  end
end

# Rails 7.0–7.1 × both concurrent-ruby versions
RAILS_COMPATIBLE_WITH_CR_1_0.each do |rails_name, rails_version|
  CONCURRENT_RUBY_VERSIONS.each do |cr_name, cr_version|
    appraise "#{rails_name}-#{cr_name}" do
      gem "rails", rails_version
      gem "concurrent-ruby", cr_version
      gem "sqlite3", "~> 1.4" # demo app boot (TEST_RAILS_INTEGRATION); 7.0 caps at < 2.0
    end
  end
end

# Rails 7.2+ × concurrent-ruby 1.3 only
RAILS_REQUIRING_CR_1_3.each do |rails_name, rails_version|
  appraise "#{rails_name}-concurrent-1.3" do
    gem "rails", rails_version
    gem "concurrent-ruby", "~> 1.3.6"
    gem "sqlite3", ">= 2.1" # demo app boot (TEST_RAILS_INTEGRATION); 8.x requires >= 2.1
  end
end
