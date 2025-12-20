# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "rubocop/rake_task"

RuboCop::RakeTask.new

namespace :gemfile do
  desc "Ensure all platforms are present in Gemfile.lock"
  task :platforms do
    require "bundler"
    platforms = %w[ruby java x86_64-darwin x86_64-linux]
    current = `bundle platform --ruby`.split("\n")
                                      .select { |l| l.start_with?("  - ") }
                                      .map { |l| l.strip.sub(/^- /, "") }

    platforms.each do |platform|
      next if current.any? { |c| c.start_with?(platform) }

      puts "Adding platform: #{platform}"
      system("bundle lock --add-platform #{platform}")
    end
  end
end

task default: %i[spec rubocop]
