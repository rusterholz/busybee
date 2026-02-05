# Busybee Internals

This document describes the internal architecture of the busybee gem. It is for maintainers and contributors who need to understand how the pieces fit together.

**Note:** This document is not linked from the README. For development setup, running tests, and release procedures, see [docs/development.md](development.md).

## Architecture Overview

```
lib/busybee/
├── client.rb                # Client class - main user-facing API
├── client/                  # Client operation modules
│   ├── error_handling.rb    # Retry logic and error wrapping
│   ├── job_operations.rb    # complete_job, fail_job, with_each_job, etc.
│   ├── message_operations.rb # publish_message, broadcast_signal
│   ├── process_operations.rb # deploy_process, start_instance, cancel_instance
│   └── variable_operations.rb # set_variables, resolve_incident
├── credentials.rb           # Credentials base class and factory
├── credentials/             # Credential implementations
│   ├── camunda_cloud.rb     # Camunda Cloud OAuth (auto-configured)
│   ├── insecure.rb          # Local development (no TLS)
│   ├── oauth.rb             # Generic OAuth2 client credentials
│   └── tls.rb               # TLS with optional client cert
├── defaults.rb              # Default values (timeouts, retry delays, etc.)
├── error.rb                 # Base error class and subclasses
├── grpc.rb                  # GRPC module entry point
├── grpc/                    # Generated protocol buffer classes
│   ├── error.rb             # GRPC::Error wrapper
│   ├── gateway_pb.rb        # Message definitions (generated)
│   └── gateway_services_pb.rb # Service stubs (generated)
├── job.rb                   # Job wrapper for activated jobs
├── job_stream.rb            # JobStream for streaming job activation
├── logging.rb               # Logging module (text/JSON formats)
├── railtie.rb               # Rails integration
├── serialization.rb         # JSON serialization/deserialization
├── testing.rb               # Testing module entry point
├── testing/                 # RSpec integration
│   ├── activated_job.rb     # Fluent job wrapper for tests
│   ├── helpers.rb           # deploy_process, with_process_instance, etc.
│   ├── helpers/
│   │   └── support.rb       # Private helper methods
│   └── matchers/            # RSpec custom matchers
│       ├── have_activated.rb
│       ├── have_available_jobs.rb
│       ├── have_received_headers.rb
│       └── have_received_variables.rb
└── version.rb               # Gem version
```

## Component Dependencies

```
                    ┌─────────────────┐
                    │  Busybee::GRPC  │  (generated, lowest level)
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
              ▼              │              │
    ┌─────────────┐          │              │
    │   Testing   │          │              │
    │   (v0.1)    │          │              │
    └─────────────┘          │              │
                             ▼              │
                    ┌─────────────┐         │
                    │   Client    │         │
                    │   (v0.2)    │         │
                    └──────┬──────┘         │
                           │                │
                           ▼                │
                    ┌─────────────┐         │
                    │   Worker    │ ────────┘
                    │   (v0.3)    │  (also uses GRPC for streaming)
                    └─────────────┘

    ┌─────────────┐
    │   Railtie   │  (optional, configures Client/Worker from Rails)
    │   (v0.2)    │
    └─────────────┘
```

- **GRPC** is the foundation; all other components build on it
- **Testing** uses GRPC directly (doesn't need Client abstraction)
- **Client** wraps GRPC with Ruby-idiomatic interface
- **Worker** uses Client for job operations, plus GRPC directly for streaming
- **Railtie** is optional; it reads Rails config and sets up gem-level configuration

## Serialization Module

`Busybee::Serialization` centralizes JSON handling for GRPC communication. This is **internal API** and may change without notice.

### Purpose

All Client methods and the Job class route JSON through this module to ensure:

1. **Consistent `as_json` behavior** — Serialization calls `as_json` before `JSON.generate`, so ActiveRecord models, Time objects, and custom classes serialize their JSON-friendly representation
2. **Consistent deserialization** — Parsing returns `HashWithIndifferentAccess` with the `HashAccess` module mixed in for method-style access
3. **Immutability** — Deserialized hashes are deeply frozen to prevent accidental mutation

### API

```ruby
# Serialization: Ruby → JSON string
Busybee::Serialization.to_json({ orderId: 123, user: User.find(1) })
# => '{"orderId":123,"user":{"id":1,"name":"Alice",...}}'

# Deserialization: JSON string → frozen hash with method access
hash = Busybee::Serialization.from_json('{"orderId":123}')
hash[:orderId]     # => 123
hash["orderId"]    # => 123
hash.orderId       # => 123
hash.order_id      # => 123 (snake_case → camelCase lookup)
hash.frozen?       # => true
```

### HashAccess Module

The `Busybee::Serialization::HashAccess` module provides method-style access with automatic snake_case to camelCase conversion:

- `hash.order_id` looks for `"order_id"` first, then `"orderId"`
- Nested hashes also get this behavior
- Only responds to methods that correspond to existing keys (no silent `nil` returns)

### Usage in Codebase

| Location | Uses |
|----------|------|
| `Client::ProcessOperations` | `to_json` for `vars` |
| `Client::MessageOperations` | `to_json` for `vars` |
| `Client::VariableOperations` | `to_json` for `vars` |
| `Client::JobOperations` | `to_json` for `vars` |
| `Job#variables`, `Job#headers` | `from_json` |
| `Testing::ActivatedJob` | `from_json` |
| `Testing::Helpers` | `to_json` for test variable setup |
