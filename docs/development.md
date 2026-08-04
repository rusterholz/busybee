# Development Guide

This guide covers setting up a development environment for working on busybee, running tests, and releasing new versions.

## Setup

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`.

## Running Tests

Busybee has two types of tests:

**Unit Tests** - Fast tests that don't require external dependencies:

```bash
# Run all unit tests (default)
bundle exec rspec

# Run specific test file
bundle exec rspec spec/busybee_spec.rb
```

**Integration Tests** - Tests that connect to a real Zeebe instance via gRPC:

```bash
# Start Zeebe and wait for it to be healthy
rake zeebe:start
rake zeebe:health

# Run all integration tests
RUN_INTEGRATION_TESTS=1 bundle exec rspec --tag integration

# Run all tests (unit + integration)
RUN_INTEGRATION_TESTS=1 bundle exec rspec

# Run a specific integration test
RUN_INTEGRATION_TESTS=1 bundle exec rspec spec/integration/topology_spec.rb

# Stop Zeebe when done
rake zeebe:stop
```

Integration tests will automatically skip if Zeebe is not running, so you can safely run the full test suite without having Zeebe started. The tests use the generated GRPC classes directly to verify that the protocol buffer bindings work correctly against a real Zeebe cluster.

### Testing Error Paths with the Fault-Injection Gateway

Some of busybee's most consequential behavior only appears when the broker misbehaves: a `RESOURCE_EXHAUSTED` during job activation, a stream that dies mid-delivery, a status that arrives while a response enumerator is being read. Those paths are easy to get wrong in a test by stubbing the client, because a stub encodes what you *believe* the gateway does. When the belief is wrong, the test passes and the system is broken.

`spec/support/fault_injection_gateway.rb` removes the belief. It runs a real gRPC server implementing the Zeebe Gateway service, in-process on an ephemeral loopback port, and lets a spec program what each RPC does. Everything else — credentials, channel, stub, client, runner — is the real thing.

Tag an example group `:gateway` and it gets a fresh, started gateway, torn down afterwards:

```ruby
RSpec.describe "a worker meeting backpressure", :gateway do
  it "keeps running" do
    gateway.on(:activate_jobs) { raise GRPC::ResourceExhausted, "broker under pressure" }

    runner = Busybee::Runner::Polling.new(worker_class, runtime_config: config, client: gateway.client)
    runner.run!
  end
end
```

**The block is the gRPC handler**, so it keeps grpc-ruby's own contract: return a response message for `OK`, raise a `GRPC::BadStatus` subclass for that status, raise anything else for `UNKNOWN`. There is no separate vocabulary to learn, and no success-side helper — returning a message *is* success.

**Streaming responses stay lazy.** A server-streaming handler returns an Enumerable that is never materialized, so partial delivery followed by a failure is expressible directly, and errors surface during enumeration exactly as they do in production:

```ruby
gateway.on(:activate_jobs) do
  Enumerator.new do |yielder|
    yielder << Busybee::GRPC::ActivateJobsResponse.new(jobs: [job])
    raise GRPC::Unavailable, "broker went away mid-stream"
  end
end
```

The same property covers a stream that simply ends (let the enumerator finish) and one that hangs past a deadline (`sleep` in the block).

**Every request is recorded**, for every RPC, whether or not a behavior was programmed — so "did what I built actually reach the wire?" is answerable without programming a response first:

```ruby
expect(gateway.received(:publish_message).map(&:name)).to eq(["order-shipped"])
```

**Job payloads need real protos.** `FaultInjectionGateway.activated_job(type:, variables:, ...)` builds a genuine `Busybee::GRPC::ActivatedJob`. The Testing module's `build_test_job` cannot be used here — it fabricates the job with an RSpec double, which will not serialize.

**Transport.** The gateway binds `127.0.0.1:0` and reports what it bound as `gateway.address`. Loopback is the assumption the wider Ruby testing ecosystem already makes, and binding the loopback interface specifically (rather than `0.0.0.0`) avoids the macOS firewall prompt. If an environment cannot bind loopback, pass `bind:` to redirect — a bind failure raises an error naming that knob rather than surfacing later as a confusing connection error.

The gateway is **not** tagged `:integration`. That tag carries `skip_unless_zeebe_available`, so adopting it would skip these specs precisely when local Zeebe is down, which is the opposite of what a self-contained gateway is for. Boot and teardown cost a couple of milliseconds, so a fresh gateway per example is affordable.

**Scope.** This is maintainer-facing test infrastructure. It lives in `spec/support/` and is not part of the public `Busybee::Testing` module documented in [testing.md](testing.md); adopters testing their own workers use the helpers described there.

### CLI Integration Tests

The CLI integration tests (`spec/integration/cli/cli_spec.rb`) verify the full CLI stack by spawning `busybee` as a subprocess against a live Zeebe instance. They test end-to-end job processing, YAML configuration loading, graceful shutdown via signals, and error scenarios.

**Architecture:**
- `spec/integration/cli/test_harness.rb` — Subprocess entry point that loads busybee, test workers, sets insecure credentials, and delegates to `CLI.main`
- `spec/integration/cli/test_workers.rb` — Named worker classes (`CLITestWorker`, `CLITestWorkerA`, `CLITestWorkerB`) that write processed job keys to a signal file for test verification
- `spec/integration/cli/cli_spec.rb` — Tests that spawn the harness via `Process.spawn`, create Zeebe jobs, wait for the signal file to confirm processing, and send signals for shutdown

The signal file pattern allows the test process to detect when the subprocess has processed jobs without shared memory. Each test gets a fresh temp file.

```bash
# Run CLI integration tests
RUN_INTEGRATION_TESTS=1 bundle exec rspec spec/integration/cli/cli_spec.rb
```

### Multi-Tenancy Testing

Busybee supports testing in both single-tenant and multi-tenant modes. Integration tests are automatically filtered based on the `MULTITENANCY_ENABLED` environment variable:

**Single-Tenant Mode (default):**

```bash
# Start Zeebe in single-tenant mode
rake zeebe:start
rake zeebe:health

# Run integration tests (multi-tenant-only tests will be skipped)
RUN_INTEGRATION_TESTS=1 bundle exec rspec --tag integration
```

**Multi-Tenant Mode:**

```bash
# Start Zeebe with multi-tenancy enabled
MULTITENANCY_ENABLED=true rake zeebe:start
MULTITENANCY_ENABLED=true rake zeebe:health

# Run integration tests (single-tenant-only tests will be skipped)
MULTITENANCY_ENABLED=true RUN_INTEGRATION_TESTS=1 bundle exec rspec --tag integration
```

**Note:** Full multi-tenancy testing requires Camunda Identity service for tenant authorization. The local Docker Compose environment uses insecure mode without Identity, so `:multi_tenant_only` tests are currently marked as pending. The test infrastructure (filtering, CI matrix) is ready for when Identity is configured.

**Test Tagging:**
- `:single_tenant_only` - Only runs when multi-tenancy is disabled
- `:multi_tenant_only` - Only runs when multi-tenancy is enabled
- No tag - Runs in both modes

**CI Behavior:**

CI automatically runs integration tests in parallel for both modes using a matrix strategy, ensuring full coverage across single-tenant and multi-tenant configurations.

### Camunda Cloud Integration Tests

Busybee includes integration tests for **live Camunda Cloud** clusters (tagged `:camunda_cloud`). These tests verify OAuth authentication, cluster connectivity, and API operations against a real Camunda Cloud environment.

**Setup Requirements:**

1. **Create Camunda Cloud Account**: Sign up at https://signup.camunda.com/ (free trial available)
2. **Create a Cluster**: Create a Development tier cluster in your desired region (e.g., `bru-2`, `dsm-1`)
3. **Create API Client**: In Console → Clusters → [Your Cluster] → API, create a client with "Zeebe" permissions
4. **Add credentials to ~/.bashrc** (or ~/.zshrc):

   ```bash
   # Camunda Cloud credentials for integration tests
   export CAMUNDA_CLIENT_ID="your-client-id"
   export CAMUNDA_CLIENT_SECRET="your-client-secret"
   export CAMUNDA_CLUSTER_ID="your-cluster-id"
   export CAMUNDA_CLUSTER_REGION="bru-2"  # or your cluster's region
   ```

5. **macOS users only** - Add this to avoid c-ares DNS resolution issues:

   ```bash
   # gRPC DNS resolver - use native resolver on macOS (c-ares has known issues)
   # See: https://github.com/grpc/grpc/issues/19954
   export GRPC_DNS_RESOLVER=native
   ```

   The gRPC gem's default DNS resolver (c-ares) has [well-documented issues](https://github.com/grpc/grpc/issues/19954) on macOS, including [c-ares 1.20+ compatibility problems](https://github.com/grpc/grpc/issues/34669) and [DNS timeout failures](https://github.com/grpc/grpc/issues/20216). Setting `GRPC_DNS_RESOLVER=native` uses the system's native getaddrinfo()-based resolver, which works reliably on macOS.

**Running the Tests:**

```bash
# Run Camunda Cloud integration tests
# Note: Source your shell rc file first to load credentials
source ~/.bashrc  # or ~/.zshrc
RUN_CAMUNDA_CLOUD_TESTS=1 bundle exec rspec --tag camunda_cloud
```

**What These Tests Verify:**

- OAuth token acquisition with correct audience (`zeebe.camunda.io`)
- Cluster address derivation from cluster_id and region
- Authentication with and without OAuth scope parameter
- Topology API calls to live cluster
- Process deployment to live cluster

**Note:** These tests are **disabled by default** - they require explicit opt-in via `RUN_CAMUNDA_CLOUD_TESTS=1` and valid credentials. They are not run in CI. Maintainers should run these tests when making changes to OAuth or CamundaCloud credentials handling.

## Local Zeebe Development Environment

Busybee provides a Docker Compose setup for running [Zeebe](https://docs.camunda.io/docs/components/zeebe/zeebe-overview/), [ElasticSearch](https://www.elastic.co/elasticsearch), and [Operate](https://docs.camunda.io/docs/components/operate/operate-introduction/) locally. All three ship in the single `camunda/camunda` Docker image. Versions are pinned in the `.env` file at the project root.

### Version Management

All version configuration is centralized in the `.env` file at the project root. This file is committed to git and serves as the source of truth for Zeebe and ElasticSearch versions.

**Upgrading Zeebe/Camunda:**

1. Edit `.env` and update `ZEEBE_VERSION` to the desired version
2. Regenerate GRPC protocol buffers: `rake grpc:generate`
3. Restart containers: `rake zeebe:restart`
4. Run tests to verify compatibility: `rake spec`

The `.env` file ensures all developers and CI environments use consistent versions.

### Starting the Environment

```bash
# Start Zeebe and ElasticSearch containers in the background
rake zeebe:start

# Wait for services to be fully healthy and ready
rake zeebe:health

# Check container status
rake zeebe:status

# View live logs from all services
rake zeebe:logs
```

After running `rake zeebe:start`, the following services will be available:

- **Zeebe gRPC Gateway**: `localhost:26500` - Use this endpoint for busybee client connections
- **Operate UI**: http://localhost:8088 - Web interface for monitoring workflows (login: demo/demo)
- **ElasticSearch**: http://localhost:9200 - Direct access to the search engine

### Managing the Environment

```bash
# Stop containers (keeps data volumes intact)
rake zeebe:stop

# Restart containers
rake zeebe:restart

# Remove containers AND delete all data (requires confirmation)
rake zeebe:clean
```

### Available Rake Tasks

- `rake zeebe:start` - Start Zeebe and ElasticSearch containers
- `rake zeebe:stop` - Stop containers (preserves data volumes)
- `rake zeebe:status` - Display container status
- `rake zeebe:logs` - Show live logs from all containers
- `rake zeebe:health` - Wait for services to be healthy (useful in CI)
- `rake zeebe:restart` - Stop and start containers
- `rake zeebe:clean` - Remove containers and delete all data volumes

### Service Roles

- **Zeebe** — gRPC API on port 26500. This is what busybee connects to.
- **ElasticSearch** — Stores exported workflow data. Required by Operate.
- **Operate** — Web UI at http://localhost:8088 (demo/demo). Useful for inspecting workflow instances and variables during development.

### Troubleshooting

If services fail to start or become unresponsive:

1. Check logs: `rake zeebe:logs`
2. Verify containers are running: `rake zeebe:status`
3. Ensure ports 26500, 8088, 9200, and 9300 are not in use by other applications
4. Try restarting: `rake zeebe:restart`
5. If data is corrupted, clean and restart: `rake zeebe:clean` then `rake zeebe:start`

The health check task (`rake zeebe:health`) will wait up to 60 seconds for each service to become healthy. If services don't become healthy in that time, check the logs for errors.

## Demo Application

Busybee includes a full-featured demo app at `spec/demo/` — a simulated dropship fulfillment system ("Dropship Co.") that serves as both a showcase of busybee's orchestration capabilities and an integration testbed for gem development.

### Purpose

The demo app exercises busybee features in a realistic Rails application with 18 workers across 4 business domains, 3 BPMN processes with parallel gateways, multi-instance subprocesses, and process chaining. It runs as a Docker Compose stack with its own Zeebe instance, web dashboard, and simulation engine.

See `spec/demo/README.md` for full architecture details and `spec/demo/docs/internal.md` for maintainer notes on simulation tuning and internals.

### Running the Demo

```bash
# Start the full stack (web + workers + Zeebe + simulation)
spec/demo/bin/demo start

# Start at higher simulation speed
spec/demo/bin/demo start --speed 10

# Start without auto-ordering (manual mode)
spec/demo/bin/demo start --manual

# Check status
spec/demo/bin/demo status

# Stop (preserves data)
spec/demo/bin/demo stop

# Stop and destroy all data
spec/demo/bin/demo clean
```

The dashboard is at http://localhost:3000 when running.

### Smoke Testing Against the Demo App

After making changes to busybee, verify they don't break the demo app. The `test` command handles the full lifecycle — starts a fresh stack at high speed, runs orders through the pipeline, and tears down:

```bash
# Run 25 orders (default) through the full pipeline
spec/demo/bin/demo test

# Run more orders for heavier verification
spec/demo/bin/demo test 20
```

This should be run:
- **After completing a mission**, before pushing — catches regressions early
- **Before cutting a release** — final verification gate

The test starts the Docker stack at speed 30 for fast feedback, creates orders, polls until all reach "fulfilled" status, verifies final state (all shipments delivered, all drivers released), and cleans up. Exits non-zero on failure.

**Note:** The demo stack uses ports 26500 and 9200, which conflict with the gem's own Zeebe dev environment. Stop `rake zeebe:stop` first if it's running.

### Maintaining the Demo App

The demo app should be kept current as busybee evolves. When adding new features to the gem:

- **Update the demo app** to use and showcase new features where appropriate
- **Run the smoke test** to verify existing functionality isn't broken
- **Update demo docs** (`spec/demo/README.md` and `spec/demo/docs/internal.md`) if behavior changes

## Regenerating GRPC Classes

The protocol buffer classes in `lib/busybee/grpc/` are generated from the Zeebe proto file. To regenerate after upgrading Zeebe:

1. Update the Zeebe version in `.env`:
   ```
   ZEEBE_VERSION=8.9.0
   ```

2. Run the generator:
   ```bash
   rake grpc:generate
   ```

3. Restart containers to match the new version:
   ```bash
   rake zeebe:restart
   ```

4. Run tests to verify compatibility:
   ```bash
   RUN_INTEGRATION_TESTS=1 bundle exec rspec
   ```

The `grpc:generate` task fetches the proto file from the Zeebe GitHub repository for the specified version and runs `grpc_tools_ruby_protoc` to generate the Ruby classes.

## Running the Appraisal Matrix

Busybee tests against multiple dependency versions using Appraisal. The matrix covers two axes: **Rails version** and **concurrent-ruby version**.

| Axis | Versions | Notes |
|------|----------|-------|
| Rails | 7.0, 7.1, 7.2, 8.0, 8.1 | Plus "base" (no Rails) |
| concurrent-ruby | ~> 1.1.7 (floor), ~> 1.3.6 (latest) | Rails 7.2+ requires >= 1.3.1 |

This produces appraisals like `base-concurrent-1.1`, `rails-7.1-concurrent-1.3`, etc. See `Appraisals` for the full matrix.

```bash
# Generate gemfiles for each appraisal
bundle exec appraisal install

# Run tests across all appraisals
bundle exec appraisal rspec

# Run tests for a specific appraisal
bundle exec appraisal rails-7.1-concurrent-1.3 rspec
```

### Running Railtie Specs

Railtie specs require a Rails appraisal gemfile. Running them with the base gemfile will show them as pending:

```bash
# Run railtie specs with a Rails appraisal
BUNDLE_GEMFILE=gemfiles/rails_7.1_concurrent_1.3.gemfile bundle exec rspec spec/busybee/railtie_spec.rb

# Or run the full suite under a Rails appraisal
BUNDLE_GEMFILE=gemfiles/rails_7.1_concurrent_1.3.gemfile bundle exec rspec
```

### Running Rails Integration Tests (dummy app)

The `TEST_RAILS_INTEGRATION=1` env var boots a full dummy Rails app whose railtie sets gem-level config (cluster address, timeouts, credential type, etc.). These values leak into the Busybee singleton and contaminate unit specs that assume gem defaults. **Run Rails integration tests separately**, not combined with the unit suite:

```bash
# Rails integration tests only (separate run)
TEST_RAILS_INTEGRATION=1 bundle exec appraisal rails-8.1-concurrent-1.3 rspec spec/integration/rails/

# Unit + Zeebe integration tests (separate run, no TEST_RAILS_INTEGRATION)
RUN_INTEGRATION_TESTS=1 bundle exec rspec
```

Combining `TEST_RAILS_INTEGRATION=1` with the full suite will cause spurious failures in timeout, credentials, and default-value specs.

## Updating Platform Lockfiles

After touching Gemfile, Appraisals, or gemspec, ensure all platform variants are present:

```bash
bundle exec rake gemfile:platforms
```

This adds `ruby`, `x86_64-darwin`, `arm64-darwin`, and `x86_64-linux` platforms to all lockfiles.

## Gem File Contents

The gemspec uses explicit globs to control what ships in the gem.

### Verifying New Files Before PR

Before preparing a branch for PR, verify that new files are correctly included or excluded:

```bash
# Check which files from your branch would be included in the gem
ruby -e "
spec = Gem::Specification.load('busybee.gemspec')
new_files = \`git diff --name-only main...HEAD\`.split(\"\n\")
included = new_files.select { |f| spec.files.include?(f) }
excluded = new_files - included

puts 'New files that would be in gem:'
if included.empty?
  puts '  (none)'
else
  included.each { |f| puts \"  ✓ #{f}\" }
end

puts ''
puts 'New files excluded from gem:'
excluded.each { |f| puts \"  - #{f}\" }
"
```

**Review each included file** to ensure it should be user-facing. Test infrastructure, development tooling, and internal docs should be excluded.

### Full Gem Audit (Before Release)

Before each release, audit the complete file list:

```bash
ruby -e "puts Dir.glob(%w[lib/**/* docs/**/* LICENSE.txt README.md CHANGELOG.md]).reject { |f| f.include?('docs/internal.md') || f.include?('docs/development.md') }"
```

**Files that SHOULD be in the gem:**
- `lib/**/*` — All library code
- `docs/testing.md`, `docs/grpc.md`, etc. — User-facing documentation
- `LICENSE.txt`, `README.md`, `CHANGELOG.md` — Standard files

**Files that should NOT be in the gem:**
- `docs/internal.md` — Maintainer-only architecture documentation
- `docs/development.md` — This development guide
- `.github/`, `.env`, `docker-compose.yml` — CI/dev infrastructure
- `spec/`, `Gemfile`, `Rakefile`, `Appraisals` — Development files
- `proto/`, `gen-grpc.sh` — GRPC generation tooling

If you add new docs, ensure user-facing docs go in `docs/` (included) and maintainer/dev docs are excluded in the gemspec.

## Releasing a New Version

Releases are published via GitHub Actions with manual trigger (`workflow_dispatch`).

> **IMPORTANT:** Release tags must ALWAYS be created on `main`, never on feature branches. Complete all work, merge to `main`, then checkout `main` before tagging.

1. Audit gemspec files (see "Gem File Contents" above)
2. Update version in `lib/busybee/version.rb`
3. Update CHANGELOG.md with release date
4. Run full test suite: `RUN_INTEGRATION_TESTS=1 bundle exec rspec`
5. Run demo app smoke test: `spec/demo/bin/demo test`
6. Commit, PR, and merge to `main`
6. From clean `main`: trigger the release workflow, or manually:
   - `bundle exec rake build` (outputs to `pkg/`, which is gitignored — do not use raw `gem build`)
   - Verify contents: `gem unpack pkg/busybee-X.Y.Z.gem` and inspect
   - Push to RubyGems: `gem push pkg/busybee-X.Y.Z.gem`
   - Tag: `git tag vX.Y.Z && git push --tags`

## Implementation Patterns

### Enumerable Wrapper Classes

When wrapping a raw enumerable source (like a gRPC stream) with a class that transforms elements, implement `#each` yourself rather than delegating directly. This ensures all Enumerable methods work correctly with your transformed elements.

**Pattern:**

```ruby
class JobStream
  include Enumerable

  def initialize(raw_stream, client:)
    @raw_stream = raw_stream
    @client = client
  end

  def each
    return enum_for(:each) unless block_given?

    @raw_stream.each do |raw_job|
      yield Busybee::Job.new(raw_job, client: @client)
    end
  end
end
```

The important thing is that [`#each`](https://ruby-doc.org/3.4.1/Enumerable.html) yields *transformed* elements (wrapped jobs, not raw protos) and returns [`enum_for(:each)`](https://ruby-doc.org/3.4.1/Object.html#method-i-enum_for) when no block is given. See `JobStream` for the canonical implementation.
