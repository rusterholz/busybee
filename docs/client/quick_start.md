# Busybee::Client Quick Start

This tutorial gets you from zero to a deployed process and running instance in about 10 minutes. By the end, you'll have:

1. A Zeebe environment (local or Camunda Cloud)
2. Busybee configured with appropriate credentials
3. A BPMN process deployed
4. A running process instance

## Prerequisites

Before starting, you'll need:

- Ruby 3.2+
- A Zeebe environment (see "Choose Your Environment" below)
- A BPMN process file (we'll create a simple one, or you can use an existing one)

## Step 1: Install Busybee

Add to your Gemfile:

```ruby
gem "busybee"
```

Then run:

```bash
bundle install
```

## Step 2: Choose Your Environment

Busybee supports both local Zeebe (typical for development) and Camunda Cloud (recommended for production).

### Option A: Local Zeebe

For local development, you can run Zeebe using Docker. The simplest setup is:

```bash
docker run -d --name zeebe -p 26500:26500 camunda/zeebe:latest
```

For a more complete setup with Operate (the web UI for monitoring workflows), see the [Camunda Docker Compose documentation](https://docs.camunda.io/docs/self-managed/setup/deploy/local/docker-compose/).

When using local Zeebe, you'll use insecure (non-TLS) connections.

### Option B: Camunda Cloud

Camunda Cloud is Camunda's managed SaaS offering. To get started:

1. Create a free account at [camunda.io](https://camunda.io/)
2. Create a cluster (the free tier includes a development cluster)
3. Create API credentials:
   - Go to your cluster's "API" tab
   - Click "Create new client"
   - Select "Zeebe" scope
   - Save the credentials (you'll need: Client ID, Client Secret, Cluster ID, and Region)

For detailed setup instructions, see [Camunda Cloud Getting Started](https://docs.camunda.io/docs/guides/getting-started/).

## Step 3: Configure Credentials

A Busybee::Client needs to know where to find the Zeebe cluster and how to authenticate to it. There are many ways to provide or configure this information, which you can find in the [Client reference](../client.md). For the purpose of this tutorial, we'll pass this information directly to `new`:

### For Local Zeebe

```ruby
require "busybee"

client = Busybee::Client.new(
  cluster_address: "localhost:26500",
  insecure: true
)
```

### For Camunda Cloud

```ruby
require "busybee"

client = Busybee::Client.new(
  client_id: "your client ID",
  client_secret: "your client secret",
  cluster_id: "your cluster ID (typically a UUID)",
  region: "your cluster region (e.g. 'bru-2')"
)
```

### Rails Configuration

In a Rails app, configure via `config/application.rb` or an initializer:

```ruby
# config/application.rb or config/initializers/busybee.rb
Rails.application.configure do
  config.x.busybee.credential_type = :camunda_cloud
  config.x.busybee.cluster_address = ENV["CLUSTER_ADDRESS"]  # for local/TLS
  # OAuth credentials are passed to Client.new, not configured globally
end
```

## Step 4: Create a BPMN Process

BPMN (Business Process Model and Notation) files define your workflows. You can create them using:

- **Camunda Modeler** (desktop app) - Download from [camunda.com/download/modeler](https://camunda.com/download/modeler/)
- **Camunda Cloud Web Modeler** - Available in your Camunda Cloud console
- **Any BPMN 2.0 editor** - Busybee works with standard BPMN files

Here's a minimal example you can save as `simple_process.bpmn`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                  xmlns:zeebe="http://camunda.org/schema/zeebe/1.0"
                  id="Definitions_1"
                  targetNamespace="http://bpmn.io/schema/bpmn">
  <bpmn:process id="hello-world" name="Hello World" isExecutable="true">
    <bpmn:startEvent id="Start">
      <bpmn:outgoing>Flow1</bpmn:outgoing>
    </bpmn:startEvent>
    <bpmn:endEvent id="End">
      <bpmn:incoming>Flow1</bpmn:incoming>
    </bpmn:endEvent>
    <bpmn:sequenceFlow id="Flow1" sourceRef="Start" targetRef="End"/>
  </bpmn:process>
</bpmn:definitions>
```

This creates a process that starts and immediately ends. Real processes would include service tasks, gateways, and other BPMN elements.

For more about BPMN modeling, see the [Camunda BPMN documentation](https://docs.camunda.io/docs/components/modeler/bpmn/).

## Step 5: Deploy the Process

Deploy your BPMN file to Zeebe:

```ruby
# Deploy a single file
result = client.deploy_process("simple_process.bpmn")
# => { "hello-world" => 2251799813685249 }

# The result maps process IDs to definition keys
process_id = result.keys.first       # => "hello-world"
definition_key = result.values.first # => 2251799813685249

# Deploy multiple files at once
result = client.deploy_process("order.bpmn", "payment.bpmn")
# => { "order-process" => 123, "payment-process" => 456 }
```

The returned hash maps BPMN process IDs (the `id` attribute on the `<bpmn:process>` element) to process definition keys (unique identifiers assigned by Zeebe).

## Step 6: Start a Process Instance

Now start an instance of your deployed process:

```ruby
# Start a basic instance
instance_key = client.start_instance("hello-world")
# => 2251799813685300

# Start with variables
instance_key = client.start_instance("order-process",
  vars: { order_id: "ORD-123", customer: "Alice", total: 99.99 }
)

# Start a specific version (not the latest)
instance_key = client.start_instance("order-process",
  vars: { order_id: "ORD-456" },
  version: 2
)
```

The returned `instance_key` is the unique identifier for this process instance.

## Putting It All Together

Here's a complete example:

```ruby
require "busybee"

# Configure for local development
client = Busybee::Client.new(insecure: true)

# Deploy the process
deployments = client.deploy_process("workflows/order-fulfillment.bpmn")
puts "Deployed: #{deployments.keys.join(', ')}"

# Start an instance
instance_key = client.start_instance("order-fulfillment",
  vars: {
    order_id: "ORD-2024-001",
    items: ["widget", "gadget"],
    total: 149.99
  }
)
puts "Started instance: #{instance_key}"

# You can now monitor this instance in Operate (web UI)
# or interact with it via messages and signals
```

## What's Next?

Now that you have a running process instance, you might want to:

- **Cancel an instance**: `client.cancel_instance(instance_key)`
- **Publish a message** to trigger a message catch event: `client.publish_message("payment-received", correlation_key: "ORD-2024-001", vars: { amount: 149.99 })`
- **Broadcast a signal** to all waiting instances: `client.broadcast_signal("system-shutdown")`
- **Set variables** on a running instance: `client.set_variables(instance_key, vars: { status: "approved" })`

See the API Reference section below for complete documentation of all available methods.

# Credential Types

Busybee supports four credential types for different environments:

| Type | Use Case | TLS | Authentication |
|------|----------|-----|----------------|
| `:insecure` | Local development, Docker, CI | No | None |
| `:tls` | Self-hosted with TLS | Yes | Server cert only |
| `:oauth` | Self-hosted with OAuth | Yes | OAuth2 client credentials |
| `:camunda_cloud` | Camunda Cloud SaaS | Yes | OAuth2 (auto-configured) |

## Insecure Credentials

For local development with no TLS or authentication:

```ruby
client = Busybee::Client.new(insecure: true)

# Or with explicit address
client = Busybee::Client.new(insecure: true, cluster_address: "zeebe:26500")
```

## TLS Credentials

For self-hosted Zeebe with TLS but no client authentication:

```ruby
client = Busybee::Client.new(
  cluster_address: "zeebe.example.com:443",
  certificate_file: "/path/to/ca.crt"  # Optional: custom CA certificate
)
```

## OAuth Credentials

For self-hosted Zeebe with OAuth2 authentication:

```ruby
client = Busybee::Client.new(
  cluster_address: "zeebe.example.com:443",
  token_url: "https://auth.example.com/oauth/token",
  client_id: "my-client-id",
  client_secret: "my-client-secret",
  audience: "zeebe.example.com"
)
```

## Camunda Cloud Credentials

For Camunda Cloud, the cluster address and OAuth configuration are derived automatically:

```ruby
client = Busybee::Client.new(
  client_id: ENV["CAMUNDA_CLIENT_ID"],
  client_secret: ENV["CAMUNDA_CLIENT_SECRET"],
  cluster_id: ENV["CAMUNDA_CLUSTER_ID"],
  region: ENV["CAMUNDA_CLUSTER_REGION"]  # e.g., "bru-2", "us-east-1"
)
```

# Error Handling

*This section will be completed in a future update.*

# API Reference

*This section will be completed in a future update.*

## Process Operations

| Method | Description |
|--------|-------------|
| `deploy_process(*paths, tenant_id: nil)` | Deploy BPMN files |
| `start_instance(bpmn_process_id, vars: {}, version: :latest, tenant_id: nil)` | Start a process instance |
| `cancel_instance(process_instance_key, ignore_missing: false)` | Cancel a running instance |

## Message Operations

| Method | Description |
|--------|-------------|
| `publish_message(name, correlation_key:, vars: {}, ttl: nil, tenant_id: nil)` | Publish a message |
| `broadcast_signal(signal_name, vars: {}, tenant_id: nil)` | Broadcast a signal |

## Variable Operations

| Method | Description |
|--------|-------------|
| `set_variables(element_instance_key, vars: {}, local: false)` | Set variables on an instance |
| `resolve_incident(incident_key)` | Resolve an incident |
