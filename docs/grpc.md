# Low-Level GRPC Access

The `Busybee::GRPC` module contains generated protocol buffer classes from the Zeebe proto definition. This is the lowest-level interface to Zeebe available in busybee.

## When to Use This

Most users should use one of Busybee's higher-level abstractions:

- **Testing your workflows?** Busybee::Testing provides [RSpec matchers and helpers for BPMN files](./testing.md).
- **Building apps which manage process instances?** Busybee::Client provides a [Ruby-idiomatic API for all those operations](./client.md).
- **Processing jobs?** Busybee::Worker (coming in v0.3) will provide an out-of-the-box job worker framework, akin to Sidekiq or Racecar.

This GRPC layer is an escape hatch for any edge cases you may encounter which need direct access to Zeebe APIs that the higher-level abstractions don't expose. Examples might include:

- Calling RPCs not yet wrapped by the Client (e.g., `MigrateProcessInstance`, `ModifyProcessInstance`)
- Building custom tooling that needs low-level control
- Debugging or experimenting with the Zeebe API directly
- Using this layer as a drop-in, 100%-compatible replacement for the discontinued [zeebe-client](https://github.com/zeebe-io/zeebe-client-ruby) gem

> Most users won't need this, as the Testing module, Client class, and Worker pattern cover most common use cases.

## Basic Usage

```ruby
# create a stub (connection to Zeebe gateway) by hand:
require "busybee/grpc"
stub = Busybee::GRPC::Gateway::Stub.new(
  "localhost:26500",
  :this_channel_is_insecure
)

# or, equivalently:
require "busybee/credentials"
stub = Busybee::Credentials::Insecure.new(cluster_address: "localhost:26500").grpc_stub

# example: check cluster topology:
request = Busybee::GRPC::TopologyRequest.new
response = stub.topology(request)

response.brokers.each do |broker|
  puts "Broker: #{broker.host}:#{broker.port}"
  broker.partitions.each do |partition|
    puts "  Partition #{partition.partition_id}: #{partition.role}"
  end
end
```

## Authentication

For local development with an insecure connection, you can create a stub instance directly, as shown above. For TLS- or OAuth-secured clusters (like Camunda Cloud), while you _can_ construct appropriate channel credentials at the GRPC level (refer to the [grpc gem documentation](https://grpc.io/docs/languages/ruby/basics/) for details), it's easier to construct an instance of Busybee::Credentials and then obtain a correctly-configured stub instance directly from that:

```ruby
require "busybee/credentials"

credentials = Busybee::Credentials::CamundaCloud.new(
  client_id: "my-client-id",          # these can also be configured
  client_secret: "my-client-secret",  # by the Railtie or by env vars;
  cluster_id: "my-cluster-id",        # see the client documentation
  region: "my-cluster-region"         # for details
)

credentials.grpc_stub # will always return a stub instance correctly configured for CamundaCloud
```

If you have manually or automatically configured a top-level set of credentials for the gem, you can always refer to it directly from anywhere in your application to get a stub instance:

```ruby
# in config/application.rb or config/initializers/busybee.rb:
Busybee.configure do |config|
  config.credentials = Busybee::Credentials::CamundaCloud.new(...)
  # this can also be configured by the Railtie or by env vars; see client documentation for details
end

# then, anywhere in application code:
Busybee.credentials.grpc_stub
```

> We recommend _against_ storing or memoizing the return value of `credentials.grpc_stub`. The Credentials instance already memoizes it internally, so that it may handle updating or replacing it if needed.

## Reducing Verbosity

If you're making many GRPC calls, you can include the GRPC module, and then use the request class names directly:

```ruby
require "busybee/grpc"
include Busybee::GRPC

stub = Gateway::Stub.new("localhost:26500", :this_channel_is_insecure)

topology_response = stub.topology(TopologyRequest.new)

request = CreateProcessInstanceRequest.new(
  bpmn_process_id: "order-fulfillment",
  variables: { order_id: "123" }.to_json
)
response = stub.create_process_instance(request)
```

## Available Classes

The GRPC module exposes:

- `Busybee::GRPC::Gateway::Stub` - The gRPC client stub class for making calls
- Request/response classes for each RPC (e.g., `TopologyRequest`, `DeployResourceRequest`, `CreateProcessInstanceRequest`)
- Enum types and nested message types from the Zeebe proto

## Available RPCs

The Gateway service includes these RPCs:

| RPC | Description |
|-----|-------------|
| `Topology` | Get cluster topology (brokers, partitions) |
| `DeployResource` | Deploy BPMN processes and other resources |
| `CreateProcessInstance` | Start a new process instance |
| `CancelProcessInstance` | Cancel a running process instance |
| `ActivateJobs` | Activate jobs for processing (bounded) |
| `StreamActivatedJobs` | Stream jobs as they become available (long-lived) |
| `CompleteJob` | Mark a job as successfully completed |
| `FailJob` | Mark a job as failed |
| `ThrowError` | Throw a BPMN error from a job |
| `PublishMessage` | Publish a message for correlation |
| `SetVariables` | Update variables on a scope |
| `ResolveIncident` | Resolve an incident |
| `UpdateJobRetries` | Update retry count for a job |
| `UpdateJobTimeout` | Extend or shorten a job's deadline |
| `BroadcastSignal` | Broadcast a BPMN signal |
| `ModifyProcessInstance` | Modify a running process instance |
| `MigrateProcessInstance` | Migrate a process instance to a new version |

See the [Zeebe gRPC API documentation](https://docs.camunda.io/docs/apis-tools/zeebe-api/) for full details on request/response structures.
