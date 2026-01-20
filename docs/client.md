# Busybee::Client

The Busybee::Client class provides a Ruby-idiomatic interface to the Zeebe workflow engine. It wraps the low-level GRPC layer with keyword arguments, sensible defaults, and proper exception handling.

If you haven't used Zeebe or Busybee before, check out the [quick start guide](client/quick_start.md), which will get you from zero to a deployed process and running instance in about 10 minutes. This doc is a more complete explanation and reference to the Client abstraction.

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

*This section will be completed in a future update.*

## API Reference

*This section will be completed in a future update.*

### Process Operations

| Method | Description |
|--------|-------------|
| `deploy_process(*paths, tenant_id: nil)` | Deploy BPMN files |
| `start_instance(bpmn_process_id, vars: {}, version: :latest, tenant_id: nil)` | Start a process instance |
| `cancel_instance(process_instance_key, ignore_missing: false)` | Cancel a running instance |

### Message Operations

| Method | Description |
|--------|-------------|
| `publish_message(name, correlation_key:, vars: {}, ttl: nil, tenant_id: nil)` | Publish a message |
| `broadcast_signal(signal_name, vars: {}, tenant_id: nil)` | Broadcast a signal |

### Variable Operations

| Method | Description |
|--------|-------------|
| `set_variables(element_instance_key, vars: {}, local: false)` | Set variables on an instance |
| `resolve_incident(incident_key)` | Resolve an incident |
