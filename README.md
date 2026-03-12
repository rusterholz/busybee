# Busybee

**A complete Ruby toolkit for workflow-based orchestration with BPMN, running on Camunda Platform.**

If you're a Ruby shop considering workflow orchestration, you might have noticed: Camunda Platform is powerful, but the Ruby ecosystem support is thin. Busybee fills that gap. One gem, one Camunda Cloud account, and you're ready to start building. And when you're ready to scale further, Busybee is ready to grow with you, with battle-proven patterns for large distributed systems.

Busybee provides everything you need to work with Camunda Platform or self-hosted Zeebe in a Ruby world:

- **Worker Pattern Framework** - Define job handlers as classes with a clean DSL. Busybee handles polling, execution, and lifecycle.
- **Idiomatic Zeebe Client** - Ruby-native interface with keyword arguments, sensible defaults, and proper exception handling.
- **RSpec Testing Integration** - Deploy BPMNs, activate jobs, and assert on workflow behavior in your test suite.
- **Deployment Tools** - CI/CD tooling for deploying BPMN files to your clusters.
- **Low-Level GRPC Access** - Direct access to Zeebe's protocol buffer API when you need it.

## Roadmap & Availability

| Version | Features | Status |
|---------|---------|--------|
| v0.1 | BPMN Testing Tools, GRPC Layer | Available now! |
| v0.2 | Client, Rails Integration | Available now! |
| v0.3 | Worker Pattern & CLI | Available now! |
| v0.4 | Instrumentation Hooks, Deployment Tools | Mid 2026 |
| v1.0 | Production Polish | Late 2026 |

## Installation

Add busybee to your Gemfile:

```ruby
gem "busybee"
```

Then run:

```bash
bundle install
```

Or install directly:

```bash
gem install busybee
```

## Usage

### Worker Pattern Framework (available now!)

Define job handlers as Ruby classes. Busybee manages the process lifecycle, the connection to Camunda Cloud, and requesting jobs from Zeebe. If you've used Sidekiq to build background jobs, this should feel very familiar.

```ruby
class ProcessOrderWorker < Busybee::Worker
  job_type "process_order"

  variable :order_id, type: :uuid
  variable :customer_email, required: false

  output :confirmation_number, type: :string

  def perform
    order = Order.find(order_id)
    confirmation = order.process!
    EmailService.send_confirmation(customer_email, confirmation) if customer_email
    { confirmation_number: confirmation }
  end
end
```

Run workers from the command line:

```bash
bundle exec busybee ProcessOrderWorker ShipOrderWorker

# Or with a YAML config file
bundle exec busybee --config config/busybee.yml
```

Capabilities:

- Declarative input/output definitions with validation and accessor methods
- Automatic job completion and failure reporting
- Three worker modes (polling, streaming, hybrid) for different workload patterns
- Configurable timeouts, retry backoff, and backpressure handling
- Graceful shutdown on SIGTERM/SIGINT
- YAML configuration with per-worker overrides
- RSpec matchers for unit testing workers without Zeebe

**[Full worker documentation &rarr;](docs/workers.md)**

### Idiomatic Zeebe Client (available now!)

A Ruby-native client for Zeebe with keyword arguments, sensible defaults, and proper exception handling.

```ruby
# Connect to Camunda Cloud with environment variables
# (CAMUNDA_CLIENT_ID, CAMUNDA_CLIENT_SECRET, CAMUNDA_CLUSTER_ID, CAMUNDA_CLUSTER_REGION)
client = Busybee::Client.new

# Deploy a workflow
client.deploy_process("workflows/order-fulfillment.bpmn")

# Start a process instance
instance_key = client.start_instance("order-fulfillment",
  vars: { order_id: "123", items: ["widget", "gadget"] }
)

# Publish a message
client.publish_message("payment-received",
  correlation_key: "order-123",
  vars: { amount: 99.99 }
)

# Process jobs (for ad-hoc use; for production job processing, use the Worker pattern above)
client.with_each_job("send-confirmation") do |job|
  EmailService.send(job.variables.customer_email)
  job.complete!(sent_at: Time.now.iso8601)
end
```

Capabilities:

- Multiple credential types (Insecure, TLS, OAuth, Camunda Cloud) with automatic detection
- Complete process lifecycle: deploy, start, cancel, set variables, resolve incidents
- Job operations: activate, complete, fail, throw BPMN errors, streaming
- Rails integration via Railtie with `config.x.busybee.*` configuration
- GRPC error wrapping with configurable retry

**[Full client documentation →](docs/client.md)**

### RSpec Testing Integration (available now!)

Allows you to unit test your BPMN files. Deploy processes, create instances, activate jobs, and verify workflow behavior against a real Zeebe instance.

#### Setup

```ruby
# spec/spec_helper.rb
require "rspec"
require "busybee/testing"

# Optional: defaults to localhost:26500, or set CLUSTER_ADDRESS env var
Busybee.configure do |config|
  config.cluster_address = "localhost:26500"
end
```

#### Example

```ruby
RSpec.describe "Order Fulfillment" do
  let(:process_id) { deploy_process("spec/fixtures/order.bpmn", uniquify: true)[:process_id] }

  it "processes payment and ships order" do
    with_process_instance(process_id, order_id: "123", total: 99.99) do
      expect(activate_job("process-payment"))
        .to have_activated
        .with_variables(order_id: "123", total: 99.99)
        .and_complete(payment_id: "pay-456")

      expect(activate_job("prepare-shipment"))
        .to have_activated
        .with_variables(payment_id: "pay-456")
        .and_complete(tracking_number: "TRACK789")

      assert_process_completed!
    end
  end
end
```

#### Helpers and Matchers

- `deploy_process(path, uniquify:)` - Deploy BPMN files with optional unique IDs for test isolation
- `with_process_instance(process_id, variables)` - Create instances with automatic cleanup
- `activate_job(type)` / `activate_jobs(type, max_jobs:)` - Activate jobs for assertions
- `publish_message(name, correlation_key:, variables:)` - Trigger message catch events
- `set_variables(scope_key, variables)` - Update process variables
- `assert_process_completed!` - Verify workflow reached an end event
- `have_activated`, `have_received_variables`, `have_received_headers` - RSpec matchers

**For more info, see our [full testing documentation here](docs/testing.md).** For unit testing workers, see [Workers: Testing Workers](docs/workers.md#testing-workers).

### Deployment Tools (coming in mid 2026)

CI/CD tooling for deploying BPMN processes to your Zeebe clusters. Version tracking, environment-specific deployments, and pre-deployment validation.

### Low-Level GRPC Access (available now!)

For edge cases where the higher-level abstractions don't cover what you need, busybee exposes the raw GRPC interface to Zeebe. This is a complete drop-in replacement for the now-discontinued [zeebe-client](https://github.com/zeebe-io/zeebe-client-ruby) gem.

> Most users won't need this, as the Testing module, Client class, and Worker pattern cover most common use cases.

```ruby
require "busybee/grpc"

stub = Busybee::GRPC::Gateway::Stub.new(
  "localhost:26500",
  :this_channel_is_insecure
)

request = Busybee::GRPC::TopologyRequest.new
response = stub.topology(request)
puts response.brokers.map(&:host)
```

**For more info, see the [full GRPC documentation here](docs/grpc.md).**

### Demo Application

The [Dropship Co. demo app](spec/demo/README.md) is a multi-domain Rails application that showcases busybee in action. It orchestrates order fulfillment across warehousing, logistics, and delivery services using BPMN workflows and busybee workers. It's a good place to see realistic usage patterns and to experiment with the framework.

## Ruby Implementation Support

Busybee currently only supports MRI (CRuby). This is due to the state of `grpc` support on other implementations. JRuby is not supported because it cannot run C extensions (it would require `grpc-java` with a Ruby wrapper). TruffleRuby's C extension support is experimental and the `grpc` gem does not currently build on it.

If you successfully run busybee on an alternative Ruby implementation, please open a GitHub issue to let us know! We'd welcome contributions to expand platform support.

## Development

Busybee includes a Docker Compose setup for running Zeebe locally, plus rake tasks for common development workflows:

```bash
bin/setup              # Install dependencies
rake zeebe:start       # Start local Zeebe + ElasticSearch
rake zeebe:health      # Wait for services to be ready
bundle exec rspec      # Run unit tests
RUN_INTEGRATION_TESTS=1 bundle exec rspec  # Run all tests including integration
```

**The full development guide for contributors [is available here](docs/development.md),** including local environment setup, running tests, regenerating GRPC classes, and release procedures.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/rusterholz/busybee. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/rusterholz/busybee/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Busybee project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/rusterholz/busybee/blob/main/CODE_OF_CONDUCT.md).
