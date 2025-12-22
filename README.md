# Busybee

...buzz buzz...

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'busybee'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install busybee

## Usage

...

### Ruby Implementation Support

Busybee currently only supports MRI (CRuby). JRuby is not supported because it cannot run C extensions (it would require `grpc-java` with a Ruby wrapper). TruffleRuby's C extension support is experimental and the `grpc` gem does not currently build on it.

If you successfully run busybee on an alternative Ruby implementation, please open an issue. We'd welcome contributions to expand platform support!

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

### Running Tests

Busybee has two types of tests:

**Unit Tests** - Fast tests that don't require external dependencies:

```bash
# Run all unit tests (default)
bundle exec rspec

# Run specific test file
bundle exec rspec spec/busybee_spec.rb
```

**Integration Tests** - Tests that connect to a real Zeebe instance via gRPC:

```bash
# Start Zeebe and wait for it to be healthy
rake zeebe:start
rake zeebe:health

# Run all integration tests
RUN_INTEGRATION_TESTS=1 bundle exec rspec --tag integration

# Run all tests (unit + integration)
RUN_INTEGRATION_TESTS=1 bundle exec rspec

# Run a specific integration test
RUN_INTEGRATION_TESTS=1 bundle exec rspec spec/integration/topology_spec.rb

# Stop Zeebe when done
rake zeebe:stop
```

Integration tests will automatically skip if Zeebe is not running, so you can safely run the full test suite without having Zeebe started. The tests use the generated GRPC classes directly to verify that the protocol buffer bindings work correctly against a real Zeebe cluster.

### Local Zeebe Development Environment

Busybee provides a Docker Compose setup for running Zeebe and ElasticSearch locally. This environment includes:

- **Zeebe Gateway & Broker**: Camunda Platform 8.8.8 - handles workflow orchestration and gRPC communication
- **ElasticSearch**: Version 8.17.10 - stores workflow data and powers the Operate UI
- **Operate UI**: Web interface for monitoring workflows at http://localhost:8088 (credentials: demo/demo)

#### Version Management

All version configuration is centralized in the `.env` file at the project root. This file is committed to git and serves as the source of truth for Zeebe and ElasticSearch versions.

**Upgrading Zeebe/Camunda:**

1. Edit `.env` and update `ZEEBE_VERSION` to the desired version
2. Regenerate GRPC protocol buffers: `rake grpc:generate`
3. Restart containers: `rake zeebe:restart`
4. Run tests to verify compatibility: `rake spec`

The `.env` file ensures all developers and CI environments use consistent versions.

#### Starting the Environment

```bash
# Start Zeebe and ElasticSearch containers in the background
rake zeebe:start

# Wait for services to be fully healthy and ready
rake zeebe:health

# Check container status
rake zeebe:status

# View live logs from all services
rake zeebe:logs
```

After running `rake zeebe:start`, the following services will be available:

- **Zeebe gRPC Gateway**: `localhost:26500` - Use this endpoint for busybee client connections
- **Operate UI**: http://localhost:8088 - Web interface for monitoring workflows (login: demo/demo)
- **ElasticSearch**: http://localhost:9200 - Direct access to the search engine

#### Managing the Environment

```bash
# Stop containers (keeps data volumes intact)
rake zeebe:stop

# Restart containers
rake zeebe:restart

# Remove containers AND delete all data (requires confirmation)
rake zeebe:clean
```

#### Available Rake Tasks

- `rake zeebe:start` - Start Zeebe and ElasticSearch containers
- `rake zeebe:stop` - Stop containers (preserves data volumes)
- `rake zeebe:status` - Display container status
- `rake zeebe:logs` - Show live logs from all containers
- `rake zeebe:health` - Wait for services to be healthy (useful in CI)
- `rake zeebe:restart` - Stop and start containers
- `rake zeebe:clean` - Remove containers and delete all data volumes

#### What Each Service Does

**Zeebe** is a workflow orchestration engine that executes BPMN workflows. It exposes a gRPC API (port 26500) that the busybee gem uses to deploy workflows, create workflow instances, and interact with jobs. The Zeebe broker stores workflow state and manages job distribution.

**ElasticSearch** stores historical and current workflow data exported from Zeebe. This data powers the Operate web interface and enables searching and analyzing workflow execution.

**Operate UI** is a web application that provides visibility into running and completed workflows. You can inspect workflow instances, view variables, and troubleshoot issues. Access it at http://localhost:8088 with username `demo` and password `demo`.

#### Troubleshooting

If services fail to start or become unresponsive:

1. Check logs: `rake zeebe:logs`
2. Verify containers are running: `rake zeebe:status`
3. Ensure ports 26500, 8088, 9200, and 9300 are not in use by other applications
4. Try restarting: `rake zeebe:restart`
5. If data is corrupted, clean and restart: `rake zeebe:clean` then `rake zeebe:start`

The health check task (`rake zeebe:health`) will wait up to 60 seconds for each service to become healthy. If services don't become healthy in that time, check the logs for errors.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/rusterholz/busybee. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/rusterholz/busybee/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Busybee project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/rusterholz/busybee/blob/main/CODE_OF_CONDUCT.md).
