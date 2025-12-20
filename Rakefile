# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "rubocop/rake_task"

RuboCop::RakeTask.new

namespace :gemfile do
  desc "Ensure all platforms are present in Gemfile.lock and Appraisal gemfiles"
  task :platforms do
    platforms = %w[ruby x86_64-darwin x86_64-linux]

    # Helper to check and add missing platforms for a gemfile
    check_and_add_platforms = lambda do |gemfile_path|
      env = gemfile_path == "Gemfile" ? {} : { "BUNDLE_GEMFILE" => gemfile_path }
      current = `#{env.map { |k, v| "#{k}=#{v}" }.join(" ")} bundle platform`.split("\n")
                                                                             .select { |l| l.start_with?("* ") }
                                                                             .map { |l| l.sub(/^\* /, "") }

      platforms.each do |platform|
        next if current.any? { |c| c.start_with?(platform) }

        puts "Adding platform #{platform} to #{gemfile_path}"
        system(env, "bundle lock --add-platform #{platform}")
      end
    end

    # Check main Gemfile
    puts "Checking Gemfile.lock..."
    check_and_add_platforms.call("Gemfile")

    # Check all Appraisal gemfiles
    Dir.glob("gemfiles/*.gemfile").each do |gemfile|
      puts "Checking #{gemfile}.lock..."
      check_and_add_platforms.call(gemfile)
    end
  end
end

task default: %i[spec rubocop]

# GRPC code generation
namespace :grpc do
  desc "Generate Ruby code from Zeebe protocol buffers"
  task :generate do
    sh "./gen-grpc.sh"
  end
end

# Docker Compose tasks for Zeebe development environment
namespace :zeebe do
  desc "Start Zeebe and ElasticSearch containers"
  task :start do
    puts "Starting Zeebe and ElasticSearch containers..."
    system("docker-compose up -d") || abort("Failed to start containers")
    puts "\nContainers started! Services will be available at:"
    puts "  - Zeebe gRPC Gateway: localhost:26500"
    puts "  - Operate UI: http://localhost:8088 (demo/demo)"
    puts "  - ElasticSearch: http://localhost:9200"
    puts "\nRun 'rake zeebe:logs' to view logs"
    puts "Run 'rake zeebe:status' to check container status"
    puts "Run 'rake zeebe:health' to wait for services to be ready"
  end

  desc "Stop Zeebe and ElasticSearch containers"
  task :stop do
    puts "Stopping Zeebe and ElasticSearch containers..."
    system("docker-compose down") || abort("Failed to stop containers")
    puts "Containers stopped."
  end

  desc "Show logs from Zeebe and ElasticSearch containers"
  task :logs do
    puts "Showing logs (Ctrl+C to exit)..."
    system("docker-compose logs -f")
  end

  desc "Check status of Zeebe and ElasticSearch containers"
  task :status do
    system("docker-compose ps")
  end

  desc "Wait for Zeebe and ElasticSearch to be healthy"
  task :health do
    puts "Waiting for services to be healthy..."

    max_attempts = 60
    attempt = 0

    # Wait for ElasticSearch
    print "Checking ElasticSearch (port 9200)..."
    until system("curl -sf http://localhost:9200/_cluster/health > /dev/null 2>&1")
      attempt += 1
      abort("\n\nElasticSearch did not become healthy within #{max_attempts} seconds") if attempt >= max_attempts
      print "."
      sleep 1
    end
    puts " OK"

    # Wait for Zeebe Gateway
    attempt = 0
    print "Checking Zeebe Gateway (port 26500)..."
    until system("nc -z localhost 26500 > /dev/null 2>&1")
      attempt += 1
      abort("\n\nZeebe Gateway did not become healthy within #{max_attempts} seconds") if attempt >= max_attempts
      print "."
      sleep 1
    end
    puts " OK"

    puts "\nAll services are healthy and ready!"
    puts "  - Zeebe gRPC Gateway: localhost:26500"
    puts "  - Operate UI: http://localhost:8088"
    puts "  - ElasticSearch: http://localhost:9200"
  end

  desc "Remove all Zeebe and ElasticSearch containers and volumes"
  task :clean do
    puts "Removing containers and volumes..."
    puts "WARNING: This will delete all Zeebe workflow data and ElasticSearch indices!"
    print "Are you sure? (y/N): "
    confirmation = $stdin.gets.chomp
    if confirmation.downcase == "y"
      system("docker-compose down -v") || abort("Failed to remove containers and volumes")
      puts "Containers and volumes removed."
    else
      puts "Aborted."
    end
  end

  desc "Restart Zeebe and ElasticSearch containers"
  task :restart do
    Rake::Task["zeebe:stop"].invoke
    Rake::Task["zeebe:start"].invoke
  end
end
