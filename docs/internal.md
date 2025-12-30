# Busybee Internals

This document describes the internal architecture of the busybee gem. It is for maintainers and contributors who need to understand how the pieces fit together.

**Note:** This document is not linked from the README. For development setup, running tests, and release procedures, see [docs/development.md](development.md).

## Architecture Overview

```
lib/busybee/
├── grpc/                    # Generated protocol buffer classes
│   ├── gateway_pb.rb        # Message definitions
│   └── gateway_services_pb.rb  # Service stubs
├── testing/                 # RSpec integration
│   ├── configuration.rb     # Testing.configure block
│   ├── helpers.rb           # deploy_process, with_process_instance, etc.
│   ├── activated_job.rb     # Fluent job wrapper
│   └── matchers.rb          # have_activated, have_received_variables, etc.
├── grpc.rb                  # GRPC module entry point
├── testing.rb               # Testing module entry point
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
