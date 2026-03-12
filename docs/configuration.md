# Gem Configuration

Busybee provides a flexible configuration system that adapts to different environments — from local development with Docker to production deployments with Camunda Cloud. Configuration can be set through Ruby code, environment variables, or Rails configuration, with sensible defaults that work out of the box.

This document covers gem-level settings: connection, credentials, logging, and operation defaults. For worker runtime configuration (CLI flags, YAML files, worker modes, and the config precedence chain), see [Workers: Running Workers](workers.md#running-workers).

## Quick Start

Most Busybee configuration is optional. The simplest setup requires no configuration at all for local development:

```ruby
# Connects to localhost:26500 with insecure credentials
client = Busybee::Client.new
```

For Camunda Cloud, set environment variables and Busybee auto-detects the credential type:

```bash
export CAMUNDA_CLIENT_ID="your-client-id"
export CAMUNDA_CLIENT_SECRET="your-client-secret"
export CAMUNDA_CLUSTER_ID="your-cluster-id"
export CAMUNDA_CLUSTER_REGION="bru-2"
```

```ruby
# Automatically uses Camunda Cloud credentials
client = Busybee::Client.new
```

For more control, use the configure block:

```ruby
Busybee.configure do |config|
  config.cluster_address = "zeebe.example.com:443"
  config.credential_type = :oauth
  config.logger = Logger.new($stdout)
  config.grpc_retry_enabled = true
end
```

## Configuration Methods

There are three ways to configure Busybee, which can be mixed as needed.

### Configure Block

The `Busybee.configure` block is the recommended approach for application setup:

```ruby
# config/initializers/busybee.rb (or anywhere during app boot)
Busybee.configure do |config|
  config.cluster_address = ENV.fetch("ZEEBE_ADDRESS")
  config.credential_type = :oauth
  config.logger = Rails.logger
  config.log_format = :json
  config.grpc_retry_enabled = true
end
```

### Direct Assignment

Configuration attributes can also be set directly:

```ruby
Busybee.cluster_address = "zeebe:26500"
Busybee.logger = Logger.new($stdout)
```

### Environment Variables

Several configuration options fall back to environment variables when not explicitly set:

| Attribute | Environment Variable | Notes |
|-----------|---------------------|-------|
| `cluster_address` | `CLUSTER_ADDRESS` | Falls back to `localhost:26500` |
| `credential_type` | `BUSYBEE_CREDENTIAL_TYPE` | One of: insecure, tls, oauth, camunda_cloud |
| `worker_name` | `BUSYBEE_WORKER_NAME` | Falls back to hostname |

Credential-specific environment variables are documented in [Client: Environment Variables](client.md#environment-variables).

## Configuration Reference

### Connection Settings

#### `cluster_address`

The Zeebe gateway address in `host:port` format.

| | |
|--|--|
| **Type** | String |
| **Default** | `"localhost:26500"` |
| **Env var** | `CLUSTER_ADDRESS` |

```ruby
Busybee.cluster_address = "zeebe.example.com:443"
```

#### `credential_type`

Explicitly selects the credential type. When set, `Credentials.build` uses this type rather than auto-detecting from parameters.

| | |
|--|--|
| **Type** | Symbol |
| **Default** | `nil` (auto-detect) |
| **Env var** | `BUSYBEE_CREDENTIAL_TYPE` |
| **Valid values** | `:insecure`, `:tls`, `:oauth`, `:camunda_cloud` |

```ruby
Busybee.credential_type = :oauth
```

See [Client: Providing Credentials](client.md#providing-credentials) for detailed credential configuration.

#### `credentials`

An explicit `Busybee::Credentials` object. When set, this is used directly rather than building credentials from parameters.

| | |
|--|--|
| **Type** | `Busybee::Credentials` |
| **Default** | `nil` |

```ruby
Busybee.credentials = Busybee::Credentials::TLS.new(
  cluster_address: "zeebe.example.com:443",
  certificate_file: "/path/to/ca.crt"
)
```

### Logging

#### `logger`

The logger instance for Busybee messages. When `nil`, logging is disabled.

| | |
|--|--|
| **Type** | Logger-compatible object |
| **Default** | `nil` (Rails: `Rails.logger`) |

```ruby
Busybee.logger = Logger.new($stdout)
```

#### `log_format`

Controls log message formatting.

| | |
|--|--|
| **Type** | Symbol |
| **Default** | `:text` |
| **Valid values** | `:text`, `:json` |

**Text format** (default):
```
[busybee] Retrying after GRPC error (attempt: 1, error: "Unavailable")
```

**JSON format**:
```json
{"message":"[busybee] Retrying after GRPC error","level":"warn","attempt":1,"error":"Unavailable"}
```

```ruby
Busybee.log_format = :json
```

### GRPC Retry

Busybee can automatically retry failed GRPC calls for transient errors. Retry is disabled by default.

#### `grpc_retry_enabled`

Whether to retry failed GRPC calls.

| | |
|--|--|
| **Type** | Boolean |
| **Default** | `false` |

```ruby
Busybee.grpc_retry_enabled = true
```

#### `grpc_retry_delay_ms`

Delay in milliseconds before retrying a failed GRPC call.

| | |
|--|--|
| **Type** | Integer |
| **Default** | `500` |

```ruby
Busybee.grpc_retry_delay_ms = 1000
```

#### `grpc_retry_errors`

GRPC error classes that trigger a retry.

| | |
|--|--|
| **Type** | Array of GRPC error classes |
| **Default** | `[GRPC::Unavailable, GRPC::DeadlineExceeded, GRPC::ResourceExhausted]` |

```ruby
# Only retry on Unavailable
Busybee.grpc_retry_errors = [GRPC::Unavailable]
```

### Operation Defaults

#### `default_message_ttl`

Default time-to-live for published messages, in milliseconds. Individual `publish_message` calls can override this.

| | |
|--|--|
| **Type** | Integer (milliseconds) |
| **Default** | `10_000` (10 seconds) |

```ruby
Busybee.default_message_ttl = 60_000  # 1 minute
```

#### `default_fail_job_backoff`

Default backoff time when failing a job, in milliseconds. Individual `fail_job` calls can override this.

| | |
|--|--|
| **Type** | Integer (milliseconds) |
| **Default** | `5_000` (5 seconds) |

```ruby
Busybee.default_fail_job_backoff = 10_000  # 10 seconds
```

#### `default_job_request_timeout`

Default timeout for job activation requests, in milliseconds. This controls how long the Zeebe gateway waits for jobs to become available before returning an empty response. Individual `with_each_job` and `activate_job` calls can override this.

| | |
|--|--|
| **Type** | Integer (milliseconds) or ActiveSupport::Duration |
| **Default** | `60_000` (60 seconds) |

```ruby
Busybee.default_job_request_timeout = 30_000   # 30 seconds
Busybee.default_job_request_timeout = 30.seconds
```

#### `default_job_lock_timeout`

Default lock timeout for activated jobs, in milliseconds. This controls how long a worker has to process a job before the lock expires and the job becomes available to other workers. Individual `with_each_job` and `open_job_stream` calls can override this.

| | |
|--|--|
| **Type** | Integer (milliseconds) or ActiveSupport::Duration |
| **Default** | `60_000` (60 seconds) |

```ruby
Busybee.default_job_lock_timeout = 120_000   # 2 minutes
Busybee.default_job_lock_timeout = 2.minutes
```

#### `worker_name`

Identifier for this worker instance, used in job activation. Useful for debugging which worker processed a job.

| | |
|--|--|
| **Type** | String |
| **Default** | Hostname (via `Socket.gethostname`) |
| **Env var** | `BUSYBEE_WORKER_NAME` |

```ruby
Busybee.worker_name = "worker-#{Process.pid}"
```

## Rails Integration

When Rails is detected, Busybee automatically loads a Railtie that:

1. Sets `Busybee.logger` to `Rails.logger`
2. Reads configuration from `config.x.busybee.*`

### Basic Rails Setup

```ruby
# config/application.rb
module MyApp
  class Application < Rails::Application
    config.x.busybee.cluster_address = "zeebe.example.com:443"
    config.x.busybee.credential_type = :oauth
  end
end
```

### Environment-Specific Configuration

```ruby
# config/environments/development.rb
Rails.application.configure do
  config.x.busybee.cluster_address = "localhost:26500"
  # credential_type not set - defaults to :insecure for local development
end

# config/environments/production.rb
Rails.application.configure do
  config.x.busybee.cluster_address = ENV.fetch("ZEEBE_CLUSTER_ADDRESS")
  config.x.busybee.credential_type = :oauth
  config.x.busybee.grpc_retry_enabled = true
end
```

### Separate Initializer

For more complex configuration, use an initializer:

```ruby
# config/initializers/busybee.rb
Rails.application.config.x.busybee.tap do |busybee|
  busybee.cluster_address = ENV.fetch("ZEEBE_CLUSTER_ADDRESS", "localhost:26500")
  busybee.credential_type = Rails.env.production? ? :camunda_cloud : :insecure
  busybee.grpc_retry_enabled = Rails.env.production?
  busybee.default_message_ttl = 30_000
end
```

### Available Railtie Settings

All module-level configuration attributes can be set via `config.x.busybee.*`:

| Rails Config | Maps To |
|--------------|---------|
| `config.x.busybee.logger` | `Busybee.logger` |
| `config.x.busybee.log_format` | `Busybee.log_format` |
| `config.x.busybee.cluster_address` | `Busybee.cluster_address` |
| `config.x.busybee.credential_type` | `Busybee.credential_type` |
| `config.x.busybee.credentials` | `Busybee.credentials` |
| `config.x.busybee.worker_name` | `Busybee.worker_name` |
| `config.x.busybee.grpc_retry_enabled` | `Busybee.grpc_retry_enabled` |
| `config.x.busybee.grpc_retry_delay_ms` | `Busybee.grpc_retry_delay_ms` |
| `config.x.busybee.grpc_retry_errors` | `Busybee.grpc_retry_errors` |
| `config.x.busybee.default_message_ttl` | `Busybee.default_message_ttl` |
| `config.x.busybee.default_fail_job_backoff` | `Busybee.default_fail_job_backoff` |
| `config.x.busybee.default_job_request_timeout` | `Busybee.default_job_request_timeout` |
| `config.x.busybee.default_job_lock_timeout` | `Busybee.default_job_lock_timeout` |
| `config.x.busybee.default_worker_mode` | `Busybee.default_worker_mode` |
| `config.x.busybee.default_max_jobs` | `Busybee.default_max_jobs` |
| `config.x.busybee.default_buffer` | `Busybee.default_buffer` |
| `config.x.busybee.default_buffer_throttle` | `Busybee.default_buffer_throttle` |
| `config.x.busybee.default_backpressure_delay` | `Busybee.default_backpressure_delay` |
| `config.x.busybee.default_input_required` | `Busybee.default_input_required` |
| `config.x.busybee.default_output_required` | `Busybee.default_output_required` |
| `config.x.busybee.shutdown_on_errors` | `Busybee.shutdown_on_errors` |

**Credential configuration:**

In addition to `credential_type` and `credentials`, you can configure credential parameters directly. The Railtie builds a credentials object automatically when parameters are provided:

| Rails Config | Used By | Description |
|--------------|---------|-------------|
| `config.x.busybee.client_id` | OAuth, Camunda Cloud | OAuth client ID |
| `config.x.busybee.client_secret` | OAuth, Camunda Cloud | OAuth client secret |
| `config.x.busybee.cluster_id` | Camunda Cloud | Camunda Cloud cluster UUID |
| `config.x.busybee.region` | Camunda Cloud | Camunda Cloud region (e.g., `"bru-2"`) |
| `config.x.busybee.token_url` | OAuth | OAuth token endpoint URL |
| `config.x.busybee.audience` | OAuth | OAuth audience |
| `config.x.busybee.scope` | OAuth, Camunda Cloud | OAuth scope (optional) |
| `config.x.busybee.certificate_file` | TLS, OAuth | Path to CA certificate file |

Three approaches to credential configuration:

```ruby
# config/environments/production.rb
Rails.application.configure do
  # Option 1: Minimal - set credential_type, use ENV vars for secrets
  # (CAMUNDA_CLIENT_ID, CAMUNDA_CLIENT_SECRET, etc.)
  config.x.busybee.credential_type = :camunda_cloud

  # Option 2: Full config - use Rails encrypted credentials
  config.x.busybee.credential_type = :camunda_cloud
  config.x.busybee.client_id = Rails.application.credentials.zeebe[:client_id]
  config.x.busybee.client_secret = Rails.application.credentials.zeebe[:client_secret]
  config.x.busybee.cluster_id = Rails.application.credentials.zeebe[:cluster_id]
  config.x.busybee.region = "bru-2"

  # Option 3: Explicit credentials object
  config.x.busybee.credentials = Busybee::Credentials::OAuth.new(
    cluster_address: "zeebe.example.com:443",
    token_url: "https://auth.example.com/oauth/token",
    client_id: Rails.application.credentials.zeebe[:client_id],
    client_secret: Rails.application.credentials.zeebe[:client_secret],
    audience: "zeebe-api"
  )
end
```

When both `credential_type` and credential parameters are provided, Busybee builds the appropriate credentials object at Rails boot time. If only `credential_type` is set, credential parameters fall back to environment variables (see [Client: Environment Variables](client.md#environment-variables)).

**Logger behavior:**

- If not set, defaults to `Rails.logger`
- Set to a custom logger to override
- Set to `false` to disable logging entirely

## Configuration Precedence

When resolving configuration values, Busybee follows this precedence (highest to lowest):

1. **Explicit parameter** - Values passed directly to methods (e.g., `Client.new(cluster_address: "...")`)
2. **Module configuration** - Values set via `Busybee.configure` or direct assignment
3. **Rails configuration** - Values from `config.x.busybee.*` (when Rails is present)
4. **Environment variables** - Fallback for supported options
5. **Defaults** - Built-in default values

For credential parameters specifically, see [Client: Cluster Address Resolution](client.md#cluster-address-resolution).

## Resetting Configuration

Configuration can be reset by setting attributes to `nil`:

```ruby
Busybee.cluster_address = nil  # Reverts to ENV or default
Busybee.credential_type = nil  # Reverts to auto-detection
Busybee.logger = nil           # Disables logging
```

This is primarily useful in tests to ensure clean state between examples.

## Worker Defaults

These settings control the default behavior of [workers](workers.md) and their runners. Each can be overridden per-worker via the [Worker DSL](workers.md#dsl-quick-reference) or at deploy time via [CLI/YAML configuration](workers.md#configuration-precedence).

#### `default_worker_mode`

Default worker mode for workers.

| | |
|--|--|
| **Type** | Symbol |
| **Default** | `:hybrid` |
| **Valid values** | `:polling`, `:streaming`, `:hybrid` |

```ruby
Busybee.default_worker_mode = :polling
```

See [Workers: Worker Modes](workers.md#worker-modes) for details on each mode.

#### `default_max_jobs`

Default maximum number of jobs to fetch per polling request.

| | |
|--|--|
| **Type** | Integer |
| **Default** | `25` |

```ruby
Busybee.default_max_jobs = 50
```

#### `default_buffer`

Whether the streaming runner uses a pump thread and buffer by default.

| | |
|--|--|
| **Type** | Boolean |
| **Default** | `true` |

```ruby
Busybee.default_buffer = false
```

#### `default_buffer_throttle`

Default pump thread delay for the streaming runner's buffer.

| | |
|--|--|
| **Type** | Numeric (milliseconds), Boolean, or `nil` |
| **Default** | `false` (no throttling) |

`false` disables throttling. `true` coerces to `0` (minimal throttle). A positive number sets the delay in milliseconds (sub-millisecond Floats accepted).

```ruby
Busybee.default_buffer_throttle = 5  # 5ms pump delay
```

See [Workers: Buffer Throttle](workers.md#buffer-throttle) for guidance on choosing a value.

#### `default_backpressure_delay`

How long to wait after a backpressure error (`GRPC::ResourceExhausted`) before retrying.

| | |
|--|--|
| **Type** | Integer (milliseconds) or ActiveSupport::Duration |
| **Default** | `2_000` (2 seconds) |

```ruby
Busybee.default_backpressure_delay = 10_000
```

#### `default_input_required`

Whether worker inputs are required by default.

| | |
|--|--|
| **Type** | Boolean |
| **Default** | `true` |

```ruby
Busybee.default_input_required = false  # inputs are optional unless explicitly required
```

#### `default_output_required`

Whether worker outputs are required by default.

| | |
|--|--|
| **Type** | Boolean |
| **Default** | `true` |

```ruby
Busybee.default_output_required = false
```

#### `shutdown_on_errors`

Exception classes that trigger a graceful worker shutdown when raised during `perform`. Applies to all workers in addition to any per-worker `shutdown_on` declarations.

| | |
|--|--|
| **Type** | Array of Exception classes (or a single class, which is coerced to an Array) |
| **Default** | `[]` |

```ruby
Busybee.shutdown_on_errors = [PG::ConnectionBad, Redis::ConnectionError]
```
