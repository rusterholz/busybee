# Configuration

Busybee provides a flexible configuration system that adapts to different environments - from local development with Docker to production deployments with Camunda Cloud. Configuration can be set through Ruby code, environment variables, or Rails configuration, with sensible defaults that work out of the box.

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
