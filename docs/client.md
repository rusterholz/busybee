# Busybee::Client

The `Busybee::Client` class is the main entry point for interacting with the Zeebe workflow engine from your Ruby app. It provides methods for deploying workflows, starting and cancelling process instances, publishing messages, and activating jobs for processing. The Client wraps the low-level GRPC layer with keyword arguments, sensible defaults, and proper exception handling.

If you haven't used Zeebe or Busybee before, check out the [quick start guide](client/quick_start.md), which will get you from zero to a deployed process and running instance in about 10 minutes. This doc is a more complete explanation and reference.

| Section | Description |
|---------|-------------|
| [Providing Credentials](#providing-credentials) | How to connect and authenticate to a Zeebe cluster |
| [Error Handling](#error-handling) | Exception hierarchy and retry configuration |
| [Working with Jobs](#working-with-jobs) | Conceptual guide to job processing (polling vs streaming) |
| [API Reference](#api-reference) | Complete method documentation |
| [Configuration Reference](configuration.md) | Full configuration options (logging, retry, Rails integration) |

## Providing Credentials

An instance of Busybee::Client relies on an instance of Busybee::Credentials to tell it where to find the Zeebe cluster and how to authenticate to it.

There are four types of credentials supported by Busybee for different environments:

| Credential Class | Type Symbol | Use Cases | SSL/TLS | Authentication |
|------|----------|-----|----------------|----|
| Busybee::Credentials::Insecure | `:insecure` | Local development, Docker, CI | No | None |
| Busybee::Credentials::TLS | `:tls` | Self-hosted with SSL/TLS | Yes | Server cert only |
| Busybee::Credentials::OAuth | `:oauth` | Self-hosted with OAuth | Yes | OAuth2 client credentials |
| Busybee::Credentials::CamundaCloud | `:camunda_cloud` | Camunda Cloud SaaS | Yes | OAuth2 (auto-configured) |

The most long-form way to create a Busybee::Client is to create an instance of one of these classes first, and pass that as the argument to Client.new:

```ruby
credentials = Busybee::Credentials::Insecure.new(cluster_address: "zeebe:26500")
client = Busybee::Client.new(credentials)
```

You can also configure the gem with a single set of credentials, and call Client.new with no arguments in order to use the configured credentials implicitly:

```ruby
# in config/application.rb or config/initializers/busybee.rb:
Busybee.configure do |config|
  config.credentials = Busybee::Credentials::TLS.new(
    cluster_address: "zeebe:26500",
    certificate_file: "/path/to/ca.crt" # optional, uses system default otherwise
  )
end

# then, anywhere in application code:
client = Busybee::Client.new
```

Or, just configure the cluster_address and credential_type, and let Busybee read your secret values out of your ENV vars:

```ruby
# in config/application.rb or config/initializers/busybee.rb:
Busybee.configure do |config|
  config.cluster_address = "zeebe:26500"
  config.credential_type = :oauth # token URL, audience, scope, client ID, and client secret will be read from env vars
end

# then, anywhere in application code:
client = Busybee::Client.new
```

For testing, it can be helpful to create multiple clients with different credentials. You can always pass a complete set of credentials directly to Client.new and let it figure out what type of credentials to build automatically, if you wish:

```ruby
insecure_client = Busybee::Client.new(
  cluster_address: "insecure_cluster:26500",
  insecure: true
)

tls_client = Busybee::Client.new(
  # if cluster_address is not given to any of these, it will use the configured cluster_address (see below):
  certificate_file: "/path/to/ca.crt"
)

oauth_client = Busybee::Client.new(
  cluster_address: "oauth_cluster:26500",
  token_url: "https://auth.example.com/oauth/token",
  client_id: "my-client-id",
  client_secret: "my-client-secret",
  audience: "my-token-audience"
)

camunda_cloud_client = Busybee::Client.new(
  # for Camunda Cloud, the cluster address and OAuth configuration are derived automatically:
  client_id: "my-client-id",
  client_secret: "my-client-secret",
  cluster_id: "my-cluster-id", # usually a UUID
  region: "my-cluster-region" # e.g., "bru-2"
)
```

### Cluster Address Resolution

When `cluster_address` is not explicitly provided, Busybee uses this precedence:

1. Explicit `cluster_address:` parameter (highest priority)
2. `Busybee.cluster_address` configuration value
3. `CLUSTER_ADDRESS` environment variable
4. Default: `"localhost:26500"` (lowest priority)

This allows you to set a default cluster address once and override it selectively when needed.

### Environment Variables

For convenience, many of the credential parameters may be read implicitly from the following env vars:

| Environment Variable | Purpose | Used By |
|---------------------|---------|---------|
| `CLUSTER_ADDRESS` | Zeebe cluster address (host:port) | All credential types |
| `BUSYBEE_CREDENTIAL_TYPE` | Credential type (insecure, tls, oauth, camunda_cloud) | Auto-detection |
| `ZEEBE_TOKEN_URL` | OAuth token endpoint | OAuth |
| `ZEEBE_AUDIENCE` | OAuth audience | OAuth |
| `ZEEBE_SCOPE` | OAuth scope (optional) | OAuth |
| `ZEEBE_CERTIFICATE_FILE` | Path to CA certificate | TLS, OAuth |
| `CAMUNDA_CLIENT_ID` | OAuth client ID | OAuth, Camunda Cloud |
| `CAMUNDA_CLIENT_SECRET` | OAuth client secret | OAuth, Camunda Cloud |
| `CAMUNDA_CLUSTER_ID` | Cluster UUID | Camunda Cloud |
| `CAMUNDA_CLUSTER_REGION` | Cluster region (e.g., "bru-2") | Camunda Cloud |

## Error Handling

Busybee wraps low-level GRPC errors in Ruby exceptions that are easier to work with. The goal is to let you rescue errors by type without needing to understand GRPC status codes, while still giving you access to the underlying details when you need them.

### Error Hierarchy

All Busybee errors inherit from `Busybee::Error`, so you can rescue broadly or narrowly:

| Error Class | When Raised |
|-------------|-------------|
| `Busybee::Error` | Base class for all Busybee errors. Never raised directly; exists for `rescue Busybee::Error`. |
| `Busybee::GRPC::Error` | Any GRPC operation failure (network issues, invalid requests, server errors). See below. |
| `Busybee::InvalidOAuthResponse` | OAuth token endpoint returned invalid JSON. |
| `Busybee::InvalidJobJson` | Job variables or headers contain malformed JSON. |
| `Busybee::JobAlreadyHandled` | Attempted to complete, fail, or throw error on a job that has already been handled. |
| `Busybee::OAuthTokenRefreshFailed` | HTTP error received from OAuth refresh token endpoint. |
| `Busybee::StreamAlreadyClosed` | Attempted to iterate a job stream that was already closed. |

### GRPC::Error Wrapper Class

`Busybee::GRPC::Error` is the error you're likely to encounter most often. It wraps the underlying `::GRPC::BadStatus` exception and provides convenient accessors for GRPC-specific information:

```ruby
begin
  client.start_instance("missing-process", vars: { orderId: 123 })
rescue Busybee::GRPC::Error => e
  e.message       # => "GRPC call failed (NOT_FOUND: no process found with ID 'missing-process')"
  e.grpc_status   # => :not_found
  e.grpc_code     # => 5 (the numeric GRPC status code)
  e.grpc_details  # => "no process found with ID 'missing-process'"
  e.cause         # => #<GRPC::NotFound: ...> (the original GRPC exception)
end
```

The original GRPC exception is preserved in `#cause` through Ruby's automatic exception chaining, so you can always dig into the raw error if needed.

### Automatic Retry

Busybee can automatically retry GRPC calls that fail due to transient errors. This is disabled by default to minimize surprise, because retries can mask problems during development.

```ruby
Busybee.configure do |config|
  config.grpc_retry_enabled = true           # Enable retry (default: false)
  config.grpc_retry_delay_ms = 500           # Delay between attempts (default: 500ms)
  config.grpc_retry_errors = [               # Which errors trigger retry (default below)
    GRPC::Unavailable,
    GRPC::DeadlineExceeded,
    GRPC::ResourceExhausted
  ]
end
```

When retry is enabled, Busybee makes up to 2 attempts before raising. A warning is logged on retry:

```
[busybee] GRPC call failed, retrying in 500ms (error_class: GRPC::Unavailable)
```

If both attempts fail, the error message indicates this: `"GRPC call failed after retry"`.

## Working with Jobs

Jobs represent units of work that your application performs as part of a workflow. When a BPMN process instance reaches a service task, Zeebe creates a job that workers can claim and process. This section covers the conceptual model; see [Job Operations](#job-operations) in the API Reference for method details.

### Polling vs Streaming

Busybee provides two ways to receive jobs:

| Approach | Method | Model | Best For |
|----------|--------|-------|----------|
| Long-Polling | `with_each_job` | Request/Response | Batch processing, cron jobs, serverless functions |
| Streaming | `open_job_stream` | Push | Long-running workers, real-time processing |

**`with_each_job` (long-polling)** makes a request and waits. If jobs are available, they're returned immediately. If not, the request waits until jobs become available or the request timeout expires, then returns whatever it has. This is like checking your inbox: you see everything that's there at the moment you look, no matter when it arrived.

**`open_job_stream` (streaming)** opens a persistent connection and receives jobs as they become available. Jobs that existed before you opened the stream are NOT delivered. This is like subscribing to a magazine: you get new issues as they're published, but you don't get back issues.

This means if you start a streaming worker after jobs have already been created, those jobs won't be delivered to your stream. For workers that need to process both existing and new jobs, either:
- Use `with_each_job` in a polling loop, or
- Call `with_each_job` at startup to drain existing jobs, then switch to streaming

> The [Worker pattern framework](workers.md) makes it easy to select between these behaviors automatically via [worker modes](workers.md#worker-modes).

### The Job Object

When you receive jobs through `with_each_job` or `open_job_stream`, each job is wrapped in a `Busybee::Job` object. This is the primary way you'll interact with jobs.

**Attributes:**

| Method | Returns | Description |
|--------|---------|-------------|
| `key` | `Integer` | Unique job identifier |
| `type` | `String` | Job type (from BPMN task definition) |
| `process_instance_key` | `Integer` | The process instance this job belongs to |
| `bpmn_process_id` | `String` | The BPMN process ID |
| `retries` | `Integer` | Remaining retry attempts |
| `deadline` | `Time` | When the job lock expires (frozen Time object) |
| `variables` | `Hash` | Job input variables (with indifferent access) |
| `headers` | `Hash` | Custom headers from the BPMN task definition |
| `status` | `Symbol` | Current status: `:ready`, `:complete`, `:failed`, or `:error` |

**Variables: Reading and Writing**

When you **read** variables and headers from a job, they're returned as `ActiveSupport::HashWithIndifferentAccess`. You can access keys with strings or symbols, and they support method-style access with automatic camelCase conversion:

```ruby
client.with_each_job("process-order") do |job|
  # All of these work:
  job.variables[:orderId]      # Symbol access
  job.variables["orderId"]     # String access
  job.variables.orderId        # Method access (camelCase)
  job.variables.order_id       # Method access (snake_case → camelCase)

  # Nested hashes also support method access
  job.variables.customer.email
end
```

Variables and headers are frozen to prevent accidental mutation.

When you **write** variables (via `complete!`, `start_instance`, `publish_message`, etc.), Busybee calls `as_json` on your data before JSON-encoding it. This means objects with custom serialization—like ActiveRecord models—work sensibly:

```ruby
user = User.find(user_id)
order = Order.find(order_id)

# ActiveRecord models serialize via as_json, not inspect
job.complete!(user: user, order: order)
# => {"user": {"id": 1, "name": "Alice", ...}, "order": {"id": 42, ...}}

# Plain hashes, arrays, and primitives work as expected
job.complete!(items: ["a", "b"], count: 3, metadata: { source: "api" })
```

If you need custom serialization for your own classes, implement `as_json`.

**Actions:**

The Job object provides convenience methods that are the preferred way to complete, fail, or error jobs:

**`complete!(vars = {})`** — Complete the job with optional output variables.

```ruby
job.complete!
job.complete!(result: "success", processedAt: Time.now.iso8601)
```

**`fail!(message_or_exception, retries: nil, backoff: nil)`** — Fail the job. You can pass a string or an exception:

```ruby
job.fail!("Payment gateway timeout")
job.fail!("Rate limited", retries: 3, backoff: 30.seconds)

# Pass an exception directly—Busybee formats it nicely
begin
  risky_operation
rescue => e
  job.fail!(e)  # Message: "[ExceptionClass] message (caused by: ...)"
end
```

**`throw_bpmn_error!(code_or_exception, message = "")`** — Throw a BPMN error. You can pass a string, symbol, or exception:

```ruby
job.throw_bpmn_error!("ORDER_NOT_FOUND", "Order #{order_id} not found")
job.throw_bpmn_error!(:order_not_found)  # Symbol converted to "ORDER_NOT_FOUND"

# Pass an exception—class name becomes the error code
begin
  order = Order.find!(order_id)
rescue OrderNotFoundError => e
  job.throw_bpmn_error!(e)  # Code: "ORDER_NOT_FOUND_ERROR"
end
```

**Status Tracking:**

The Job tracks its status to prevent double-handling bugs:

```ruby
job.ready?     # => true (job can be completed/failed)
job.complete?  # => true after calling complete!
job.failed?    # => true after calling fail!
job.error?     # => true after calling throw_bpmn_error!

# Attempting to handle a job twice raises an error
job.complete!
job.fail!("oops")  # => raises Busybee::JobAlreadyHandled
```

### JobStream

`Busybee::JobStream` wraps a gRPC server stream and provides a Ruby-idiomatic interface. It includes `Enumerable`, so you can use `each`, `map`, `select`, and other collection methods.

| Method | Description |
|--------|-------------|
| `each { \|job\| ... }` | Iterate over jobs (blocks until stream closes) |
| `close` | Close the stream (idempotent) |
| `closed?` | Check if the stream has been closed |

**Gotchas:**

1. **Blocking behavior:** Calling `stream.each` blocks the calling thread indefinitely. The iteration only ends when another thread calls `stream.close`, or when the server closes the connection. Plan for this—use signal handlers or a separate management thread.

2. **Single-pass:** Streams are single-pass. Once consumed via `each` or other Enumerable methods, the stream is exhausted. If you need to process the same jobs multiple times, collect them into an array first.

3. **No back issues:** As noted in [Polling vs Streaming](#polling-vs-streaming), streams only receive jobs created *after* the stream opens.

```ruby
stream = client.open_job_stream("send-email")

# Stream blocks on each—close from another thread or signal handler
trap("INT") { stream.close }

stream.each do |job|
  puts "Processing job #{job.key}"
  job.complete!
end
# This line only runs after the stream is closed
puts "Stream closed, shutting down"
```

---

## API Reference

### Overview

| Category | Method | Description |
|----------|--------|-------------|
| [Process](#process-operations) | [`deploy_process`](#deploy_process) | Deploy BPMN files |
| | [`start_instance`](#start_instance) | Start a process instance |
| | [`cancel_instance`](#cancel_instance) | Cancel a running instance |
| [Job](#job-operations) | [`with_each_job`](#with_each_job) | Poll for jobs (bounded) |
| | [`open_job_stream`](#open_job_stream) | Stream jobs (push-based) |
| | [`complete_job`](#complete_job) | Complete a job |
| | [`fail_job`](#fail_job) | Fail a job with retry |
| | [`throw_bpmn_error`](#throw_bpmn_error) | Throw a BPMN error |
| | [`update_job_retries`](#update_job_retries) | Update job retry count |
| | [`update_job_timeout`](#update_job_timeout) | Extend job deadline |
| | [`resolve_incident`](#resolve_incident) | Resolve a failed-job incident |
| [Message](#message-operations) | [`publish_message`](#publish_message) | Publish a correlated message |
| | [`broadcast_signal`](#broadcast_signal) | Broadcast a signal to all listeners |
| [Variable](#variable-operations) | [`set_variables`](#set_variables) | Set variables on an instance |

---

### Process Operations

Process operations manage BPMN workflow deployments and instances.

#### deploy_process

Deploy one or more BPMN files to the Zeebe cluster.

```ruby
deploy_process(*paths, tenant_id: nil) → Hash{String => Integer}
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `*paths` | `String` | One or more paths to BPMN files |
| `tenant_id:` | `String`, `nil` | Tenant ID for multi-tenancy (optional) |

**Returns:** A hash mapping each BPMN process ID to its process definition key.

**Raises:** `Errno::ENOENT` if a file doesn't exist; `Busybee::GRPC::Error` if deployment fails (e.g., invalid BPMN syntax).

```ruby
# Deploy a single workflow
result = client.deploy_process("workflows/order-fulfillment.bpmn")
# => { "order-fulfillment" => 2251799813685249 }

# Deploy multiple workflows at once
result = client.deploy_process("order.bpmn", "payment.bpmn", "shipping.bpmn")
# => { "order-fulfillment" => 123, "payment-process" => 456, "shipping-process" => 789 }
```

#### start_instance

Start a new process instance from a deployed workflow.

```ruby
start_instance(bpmn_process_id, vars: {}, version: :latest, tenant_id: nil) → Integer
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `bpmn_process_id` | `String` | The BPMN process ID (from the workflow definition) |
| `vars:` | `Hash` | Variables to initialize the process with (default: `{}`) |
| `version:` | `Integer`, `:latest`, `nil` | Process version to start (default: `:latest`) |
| `tenant_id:` | `String`, `nil` | Tenant ID for multi-tenancy (optional) |

**Returns:** The process instance key (an integer uniquely identifying this instance).

**Raises:** `ArgumentError` if `vars` is not a Hash; `Busybee::GRPC::Error` if the process doesn't exist or starting fails.

```ruby
# Start with variables
instance_key = client.start_instance("order-fulfillment", vars: {
  orderId: "ORD-123",
  customer: { name: "Alice", email: "alice@example.com" }
})
# => 2251799813685300

# Start a specific version
instance_key = client.start_instance("order-fulfillment", version: 3)

# Alias: start_process_instance
instance_key = client.start_process_instance("order-fulfillment", vars: { orderId: "ORD-456" })
```

#### cancel_instance

Cancel a running process instance.

```ruby
cancel_instance(process_instance_key, ignore_missing: false) → Boolean
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `process_instance_key` | `Integer` | The process instance key to cancel |
| `ignore_missing:` | `Boolean` | Return `false` instead of raising if instance not found (default: `false`) |

**Returns:** `true` if cancelled, `false` if not found and `ignore_missing: true`.

**Raises:** `Busybee::GRPC::Error` if cancellation fails (unless instance not found and `ignore_missing: true`).

```ruby
# Cancel an instance (raises if not found)
client.cancel_instance(2251799813685300)
# => true

# Cancel without raising if already completed/cancelled
cancelled = client.cancel_instance(2251799813685300, ignore_missing: true)
# => false (if instance was already gone)

# Alias: cancel_process_instance
client.cancel_process_instance(instance_key, ignore_missing: true)
```

---

### Job Operations

For conceptual background on jobs, the Job object, and JobStream, see [Working with Jobs](#working-with-jobs) above.

#### with_each_job

Poll for available jobs and process them with a block.

```ruby
with_each_job(job_type, max_jobs: 25, job_timeout: 60_000, request_timeout: 60_000) { |job| ... } → Integer
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `job_type` | `String` | The job type to activate (from the BPMN task definition) |
| `max_jobs:` | `Integer` | Maximum jobs to return (default: 25) |
| `job_timeout:` | `Integer`, `Duration` | How long a job stays locked to this worker (default: 60s) |
| `request_timeout:` | `Integer`, `Duration` | How long to wait for jobs before returning (default: 60s) |

**Yields:** Each activated job as a `Busybee::Job` object.

**Returns:** The number of jobs processed.

**Raises:** `ArgumentError` if no block is given; `Busybee::GRPC::Error` if activation fails.

**Long-polling behavior:** If no jobs are immediately available, the request waits up to `request_timeout` for jobs to become available. When jobs arrive (or the timeout expires), the method returns with whatever jobs it collected.

**Configuration:** The worker name sent to Zeebe comes from `Busybee.worker_name`, which defaults to the machine hostname. You can override it:

```ruby
Busybee.configure do |config|
  config.worker_name = "order-processor-1"
end
```

```ruby
# Process jobs in a loop
loop do
  count = client.with_each_job("send-email", max_jobs: 10) do |job|
    EmailService.deliver(to: job.variables.email, subject: job.variables.subject)
    job.complete!(sentAt: Time.now.iso8601)
  rescue EmailService::DeliveryError => e
    job.fail!(e, backoff: 1.minute)
  end

  puts "Processed #{count} jobs"
end
```

#### open_job_stream

Open a long-lived stream for job activation. Jobs are pushed to your code as they become available.

```ruby
open_job_stream(job_type, job_timeout: 60_000) → Busybee::JobStream
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `job_type` | `String` | The job type to activate |
| `job_timeout:` | `Integer`, `Duration` | How long a job stays locked (default: 60s) |

**Returns:** A `Busybee::JobStream` object.

**Raises:** `Busybee::GRPC::Error` if stream creation fails.

**Remember:** Streams only receive jobs created *after* the stream opens. See [Polling vs Streaming](#polling-vs-streaming).

```ruby
stream = client.open_job_stream("send-email", job_timeout: 2.minutes)

# Handle graceful shutdown
trap("INT") { stream.close }
trap("TERM") { stream.close }

stream.each do |job|
  process_email(job)
  job.complete!
rescue StandardError => e
  job.fail!(e)
end

puts "Stream closed, shutting down"
```

#### complete_job

Mark a job as successfully completed, optionally returning variables to the workflow.

```ruby
complete_job(job_key, vars: {}) → Object
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `job_key` | `Integer` | The job key |
| `vars:` | `Hash` | Variables to return to the workflow (default: `{}`) |

**Returns:** A truthy response from the gateway.

**Raises:** `Busybee::GRPC::Error` if completion fails.

**Prefer `Job#complete!`** when processing jobs through `with_each_job` or `open_job_stream`.

```ruby
# Direct client call (when you only have the job key)
client.complete_job(job_key, vars: { result: "success" })

# Preferred: use the Job object
job.complete!(result: "success")
```

#### fail_job

Mark a job as failed. The workflow engine will retry the job (if retries remain) after the backoff period.

```ruby
fail_job(job_key, error_message, retries: nil, backoff: nil) → Object
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `job_key` | `Integer` | The job key |
| `error_message` | `String` | Error message describing the failure |
| `retries:` | `Integer`, `nil` | Override the remaining retry count (default: decrement by 1) |
| `backoff:` | `Integer`, `Duration`, `nil` | Delay before retry (see below) |

**Returns:** A truthy response from the gateway.

**Raises:** `Busybee::GRPC::Error` if the fail operation fails.

**Default backoff:** When `backoff:` is omitted, Busybee uses `Busybee.default_fail_job_backoff` (default: 5 seconds). You can change this globally:

```ruby
Busybee.configure do |config|
  config.default_fail_job_backoff = 30_000  # 30 seconds
end
```

**Prefer `Job#fail!`** when processing jobs through `with_each_job` or `open_job_stream`.

```ruby
# Direct client call
client.fail_job(job_key, "Payment gateway timeout", backoff: 30.seconds)

# Preferred: use the Job object
job.fail!("Payment gateway timeout", backoff: 30.seconds)
```

#### throw_bpmn_error

Throw a BPMN error that can be caught by an error boundary event in the workflow. Use this for business-level errors that the workflow is designed to handle (as opposed to technical failures, which should use `fail_job`).

```ruby
throw_bpmn_error(job_key, error_code, message: "") → Object
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `job_key` | `Integer` | The job key |
| `error_code` | `String` | BPMN error code (must match the error catch event) |
| `message:` | `String` | Optional error message for context (default: `""`) |

**Returns:** A truthy response from the gateway.

**Raises:** `Busybee::GRPC::Error` if the operation fails.

**Prefer `Job#throw_bpmn_error!`** when processing jobs through `with_each_job` or `open_job_stream`.

```ruby
# Direct client call
client.throw_bpmn_error(job_key, "ORDER_NOT_FOUND", message: "Order ORD-123 does not exist")

# Preferred: use the Job object (also accepts symbols and exceptions)
job.throw_bpmn_error!(:order_not_found, "Order ORD-123 does not exist")
```

#### update_job_retries

Update the retry count for a job. Useful for giving a job more attempts after fixing an underlying issue.

```ruby
update_job_retries(job_key, retries) → Object
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `job_key` | `Integer` | The job key |
| `retries` | `Integer` | The new retry count |

**Returns:** A truthy response from the gateway.

**Raises:** `Busybee::GRPC::Error` if the update fails.

```ruby
client.update_job_retries(job_key, 5)
```

#### update_job_timeout

Extend the deadline for a job that's taking longer than expected. Call this before the current deadline expires to prevent the job from timing out and being reassigned to another worker.

```ruby
update_job_timeout(job_key, timeout) → Object
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `job_key` | `Integer` | The job key |
| `timeout` | `Integer`, `Duration` | New timeout in milliseconds or as a Duration |

**Returns:** A truthy response from the gateway.

**Raises:** `Busybee::GRPC::Error` if the update fails.

```ruby
client.update_job_timeout(job_key, 30.seconds)
```

#### resolve_incident

Resolve an incident so the workflow can continue. Incidents occur when a job fails with no retries remaining, or when an expression evaluation fails.

```ruby
resolve_incident(incident_key) → true
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `incident_key` | `Integer` | The incident key to resolve |

**Returns:** `true` if resolved.

**Raises:** `Busybee::GRPC::Error` if the incident doesn't exist or resolution fails.

Before resolving, you typically need to fix the underlying problem (e.g., set missing variables, fix external services, or update job retries):

```ruby
# Fix the problem first
client.set_variables(process_instance_key, vars: { missingField: "now provided" })

# Or give the job more retries
client.update_job_retries(job_key, 3)

# Then resolve the incident
client.resolve_incident(incident_key)
```

---

### Message Operations

Messages enable communication with waiting process instances. A message correlates to instances by matching a correlation key against process variables.

#### publish_message

Publish a message that correlates to waiting process instances.

```ruby
publish_message(name, correlation_key:, vars: {}, ttl: nil, tenant_id: nil) → Integer
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | `String` | The message name (must match the message catch event in BPMN) |
| `correlation_key:` | `String` | Key to match against process instance variables |
| `vars:` | `Hash` | Variables to pass with the message (default: `{}`) |
| `ttl:` | `Integer`, `ActiveSupport::Duration`, `nil` | Time-to-live (see below) |
| `tenant_id:` | `String`, `nil` | Tenant ID for multi-tenancy (optional) |

**Returns:** The message key.

**Raises:** `ArgumentError` if `vars` is not a Hash; `Busybee::GRPC::Error` if publishing fails.

**Default TTL:** When `ttl:` is omitted, Busybee uses `Busybee.default_message_ttl` (default: 10 seconds). You can change this globally:

```ruby
Busybee.configure do |config|
  config.default_message_ttl = 60_000  # 1 minute, in milliseconds
end
```

The TTL determines how long the message remains buffered if no matching instance is found. If an instance starts waiting before the TTL expires, the message is delivered. After the TTL expires, the message is discarded.

```ruby
# Publish with default TTL
client.publish_message("order-confirmed", correlation_key: "ORD-123")

# Publish with variables and custom TTL using ActiveSupport::Duration
client.publish_message("payment-received",
  correlation_key: order.id.to_s,
  vars: { paymentId: payment.id, amount: payment.amount },
  ttl: 5.minutes
)

# Publish with TTL in milliseconds
client.publish_message("order-shipped", correlation_key: "ORD-123", ttl: 60_000)
```

#### broadcast_signal

Broadcast a signal to all process instances with matching signal catch events. Unlike messages, signals don't use correlation—they're delivered to all waiting instances.

```ruby
broadcast_signal(signal_name, vars: {}, tenant_id: nil) → Integer
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `signal_name` | `String` | The signal name (must match signal catch events in BPMN) |
| `vars:` | `Hash` | Variables to pass with the signal (default: `{}`) |
| `tenant_id:` | `String`, `nil` | Tenant ID for multi-tenancy (optional) |

**Returns:** The signal key.

**Raises:** `ArgumentError` if `vars` is not a Hash; `Busybee::GRPC::Error` if broadcasting fails.

```ruby
# Broadcast a simple signal
client.broadcast_signal("system-shutdown")

# Broadcast with variables
client.broadcast_signal("price-updated", vars: {
  productId: "PROD-789",
  newPrice: 29.99
})
```

---

### Variable Operations

Variable operations let you modify process instance state from outside the workflow.

#### set_variables

Set variables on a process instance or element (e.g., a service task).

```ruby
set_variables(element_instance_key, vars: {}, local: false) → Integer
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `element_instance_key` | `Integer` | The process instance key or element instance key |
| `vars:` | `Hash` | Variables to set (default: `{}`) |
| `local:` | `Boolean` | If `true`, variables are scoped locally (default: `false`) |

**Returns:** The set variables operation key.

**Raises:** `ArgumentError` if `vars` is not a Hash; `Busybee::GRPC::Error` if setting variables fails.

When `local: false` (the default), variables propagate up to the process instance scope and are visible everywhere. When `local: true`, variables are scoped to the specific element and won't be visible to parent or sibling elements.

```ruby
# Set variables on a process instance (propagates globally)
client.set_variables(process_instance_key, vars: { status: "approved", approvedBy: "manager@example.com" })

# Set local variables on a specific element (won't propagate)
client.set_variables(element_instance_key, vars: { tempCalculation: 42 }, local: true)
```
