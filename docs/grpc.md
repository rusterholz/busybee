# Low-Level GRPC Access

The `Busybee::GRPC` module contains generated protocol buffer classes from the Zeebe proto definition. This is the lowest-level interface to Zeebe available in busybee.

## When to Use This

Most users should use the higher-level abstractions:

- **Testing workflows?** Use `Busybee::Testing` (available now)
- **Building applications?** Use `Busybee::Client` (coming in v0.2)
- **Processing jobs?** Use `Busybee::Worker` (coming in v0.3)

The GRPC layer is an escape hatch for edge cases where you need direct access to Zeebe APIs that the higher-level abstractions don't expose. Examples:

- Calling RPCs not yet wrapped by the Client (e.g., `MigrateProcessInstance`, `ModifyProcessInstance`)
- Building custom tooling that needs low-level control
- Debugging or experimenting with the Zeebe API directly

## Basic Usage

```ruby
require "busybee/grpc"

# Create a stub (connection to Zeebe gateway)
stub = Busybee::GRPC::Gateway::Stub.new(
  "localhost:26500",
  :this_channel_is_insecure
)

# Check cluster topology
request = Busybee::GRPC::TopologyRequest.new
response = stub.topology(request)

response.brokers.each do |broker|
  puts "Broker: #{broker.host}:#{broker.port}"
  broker.partitions.each do |partition|
    puts "  Partition #{partition.partition_id}: #{partition.role}"
  end
end
```

## Reducing Verbosity

If you're making many GRPC calls, you can include the module to use class names directly:

```ruby
require "busybee/grpc"
include Busybee::GRPC

stub = Gateway::Stub.new("localhost:26500", :this_channel_is_insecure)

response = stub.topology(TopologyRequest.new)

request = CreateProcessInstanceRequest.new(
  bpmn_process_id: "order-fulfillment",
  variables: { order_id: "123" }.to_json
)
instance = stub.create_process_instance(request)
```

## Available Classes

The GRPC module exposes:

- `Busybee::GRPC::Gateway::Stub` - The gRPC client stub for making calls
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

## Authentication

For local development with an insecure connection:

```ruby
stub = Busybee::GRPC::Gateway::Stub.new(
  "localhost:26500",
  :this_channel_is_insecure
)
```

For Camunda Cloud or TLS-secured clusters, you'll need to construct appropriate channel credentials. The upcoming `Busybee::Client` will handle this automatically; at the GRPC level, refer to the [grpc gem documentation](https://grpc.io/docs/languages/ruby/basics/) for credential setup.
