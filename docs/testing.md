# Testing BPMN Workflows with Busybee

Busybee provides RSpec helpers and matchers for testing BPMN workflows against Zeebe. This testing module makes it easy to write integration tests that deploy processes, create instances, activate jobs, and verify workflow behavior.

## Installation

Add busybee to your `Gemfile` test group:

```ruby
group :test do
  gem "busybee"
end
```

Then run:

```bash
bundle install
```

## Setup

In your `spec/spec_helper.rb` or `rails_helper.rb`, require the testing module after RSpec:

```ruby
require "rspec"
require "busybee/testing"
```

The testing module will automatically include helper methods in all RSpec examples.

## Configuration

Configure the Zeebe connection. Busybee reads from environment variables by default, or you can configure explicitly:

```ruby
# Use environment variables (recommended)
# ZEEBE_ADDRESS=localhost:26500

# Or configure explicitly
Busybee::Testing.configure do |config|
  config.address = "localhost:26500"
  config.activate_request_timeout = 2000 # milliseconds, default: 1000
end
```

### Configuration Options

| Option | Environment Variable | Default | Description |
|--------|---------------------|---------|-------------|
| `address` | `ZEEBE_ADDRESS` | `"localhost:26500"` | Zeebe gateway gRPC address |
| `activate_request_timeout` | - | `1000` | Timeout in milliseconds for job activation requests |

## Helper Methods

### Process Deployment

#### `deploy_process(path, uniquify: nil)`

Deploys a BPMN file to Zeebe.

**Parameters:**
- `path` (String) - Path to BPMN file
- `uniquify` (nil, true, String) - Uniquification strategy:
  - `nil` (default) - Deploy with original process ID from BPMN
  - `true` - Auto-generate unique process ID like `test-process-abc123`
  - String - Use custom process ID

**Returns:** Hash with `:process` (GRPC metadata) and `:process_id` (String)

**Examples:**

```ruby
# Deploy with original process ID (most common)
result = deploy_process("spec/fixtures/order_process.bpmn")
result[:process_id] #=> "order-fulfillment" (from BPMN file)

# Deploy with auto-generated unique ID (for test isolation)
result = deploy_process("spec/fixtures/order_process.bpmn", uniquify: true)
result[:process_id] #=> "test-process-a1b2c3d4"

# Deploy with custom ID
result = deploy_process("spec/fixtures/order_process.bpmn", uniquify: "my-test-order-process")
result[:process_id] #=> "my-test-order-process"
```

### Process Instance Management

#### `with_process_instance(process_id, variables = {})`

Creates a process instance, yields its key, and automatically cancels it when the block exits. This ensures cleanup even if tests fail.

**Parameters:**
- `process_id` (String) - BPMN process ID
- `variables` (Hash) - Initial process variables (optional)

**Yields:** Integer process instance key

**Examples:**

```ruby
with_process_instance("order-fulfillment") do |key|
  # Test process behavior
  # Instance is automatically cancelled after block
end

# With initial variables
with_process_instance("order-fulfillment", order_id: "12345", items: 3) do |key|
  job = activate_job("prepare-shipment")
  expect(job.variables["order_id"]).to eq("12345")
end
```

#### `process_instance_key`

Returns the current process instance key within a `with_process_instance` block.

**Returns:** Integer or nil

```ruby
with_process_instance("my-process") do
  puts process_instance_key #=> 2251799813685255
end
```

#### `last_process_instance_key`

Returns the process instance key from the most recently completed `with_process_instance` call. Useful for debugging test failures by correlating with ElasticSearch/Operate data.

**Returns:** Integer or nil

```ruby
it "processes order" do
  with_process_instance("order-fulfillment") { ... }
end

after do
  puts "Failed process instance: #{last_process_instance_key}" if last_process_instance_key
end
```

#### `with_activated_job_instance(job_type)`

Activates a job, yields it, and automatically completes it when the block exits. Must be called within a `with_process_instance` block. This ensures cleanup even if tests fail.

**Parameters:**
- `job_type` (String) - Job type to activate

**Yields:** `ActivatedJob` instance

**Note:** If the job is already completed or failed within the block, the cleanup completion is silently ignored.

**Examples:**

```ruby
with_process_instance("order-fulfillment") do
  with_activated_job_instance("process-order") do |job|
    # Test job without worrying about cleanup
    expect(job.variables["order_id"]).to eq("123")
    client.update_job_retries(job.key, 5)
    # Job is automatically completed after block
  end
end

# Test that completes the job explicitly
with_process_instance("order-fulfillment") do
  with_activated_job_instance("process-order") do |job|
    job.mark_completed(result: "success")
    # Cleanup completion is safely ignored since job already completed
  end
end
```

### Job Activation

#### `activate_job(type, timeout: nil)`

Activates a single job of the specified type. Raises `Busybee::Testing::NoJobAvailable` if no job is available.

**Parameters:**
- `type` (String) - Job type to activate
- `timeout` (Integer, ActiveSupport::Duration, optional) - Request timeout in milliseconds. Defaults to `Busybee::Testing.activate_request_timeout` (1000ms)

**Returns:** `ActivatedJob` instance

**Raises:** `NoJobAvailable` if no matching job found

**Example:**

```ruby
job = activate_job("process-payment")
expect(job.variables["amount"]).to eq(99.99)
job.mark_completed(payment_status: "success")

# With custom timeout for faster cleanup loops
job = activate_job("process-order", timeout: 100)
```

#### `activate_jobs(type, max_jobs:, timeout: nil)`

Activates multiple jobs of the specified type.

**Parameters:**
- `type` (String) - Job type to activate
- `max_jobs` (Integer) - Maximum number of jobs to activate
- `timeout` (Integer, ActiveSupport::Duration, optional) - Request timeout in milliseconds. Defaults to `Busybee::Testing.activate_request_timeout` (1000ms)

**Returns:** Enumerator of `ActivatedJob` instances

**Example:**

```ruby
jobs = activate_jobs("send-notification", max_jobs: 5)
jobs.each do |job|
  recipient = job.variables["email"]
  job.mark_completed(sent_at: Time.now.iso8601)
end
```

### Message Publishing

#### `publish_message(name, correlation_key:, variables: {}, ttl_ms: 5000)`

Publishes a message to Zeebe to trigger message intermediate catch events or message start events.

**Parameters:**
- `name` (String) - Message name matching BPMN definition
- `correlation_key` (String) - Key to correlate message with process instance
- `variables` (Hash) - Message payload variables (optional, default: `{}`)
- `ttl_ms` (Integer) - Message time-to-live in milliseconds (optional, default: `5000`)

**Example:**

```ruby
# Process waiting for message with correlation
with_process_instance("approval-workflow", request_id: "req-123") do
  publish_message(
    "approval-granted",
    correlation_key: "req-123",
    variables: { approved_by: "manager", approved_at: Time.now.iso8601 }
  )

  assert_process_completed!
end
```

### Variable Management

#### `set_variables(scope_key, variables, local: true)`

Sets variables on a process scope (process instance or element instance).

**Parameters:**
- `scope_key` (Integer) - Element instance key
- `variables` (Hash) - Variables to set
- `local` (Boolean) - Whether variables are local to scope (default: `true`)

**Example:**

```ruby
with_process_instance("data-processing") do |key|
  set_variables(key, { processed_count: 100, status: "in_progress" })

  job = activate_job("validate-data")
  expect(job.variables["processed_count"]).to eq(100)
end
```

### Process Completion

#### `assert_process_completed!(wait: 0.25)`

Asserts that the current process instance has completed. Useful for verifying end-to-end workflow execution.

**Parameters:**
- `wait` (Float) - Seconds to wait before checking (default: `0.25`)

**Raises:** RuntimeError if process is still running

**Example:**

```ruby
with_process_instance("simple-workflow") do
  job = activate_job("single-task")
  job.mark_completed

  assert_process_completed! # Verifies workflow reached end event
end
```

### Zeebe Availability

#### `zeebe_available?(timeout: 5)`

Checks if Zeebe is available and responsive.

**Parameters:**
- `timeout` (Integer) - Timeout in seconds (default: `5`)

**Returns:** Boolean

**Example:**

```ruby
before(:all) do
  skip "Zeebe not running" unless zeebe_available?
end
```

## ActivatedJob API

The `ActivatedJob` class wraps Zeebe's GRPC job response with a fluent API for testing.

### Accessors

```ruby
job = activate_job("my-task")

job.key                    #=> 2251799813685263 (job key)
job.process_instance_key   #=> 2251799813685255 (process instance key)
job.variables              #=> {"order_id" => "123", "total" => 99.99}
job.headers                #=> {"priority" => "high"}
job.retries                #=> 3
```

### Expectation Methods

These methods verify job state and return `self` for chaining:

#### `expect_variables(expected)`

Asserts that job variables include the expected key-value pairs.

**Parameters:**
- `expected` (Hash) - Expected variable subset (symbol or string keys)

**Returns:** self

**Raises:** `RSpec::Expectations::ExpectationNotMetError` if not matched

```ruby
job.expect_variables(order_id: "123", total: 99.99)
  .and_complete
```

#### `expect_headers(expected)`

Asserts that job headers include the expected key-value pairs.

**Parameters:**
- `expected` (Hash) - Expected header subset (symbol or string keys)

**Returns:** self

**Raises:** `RSpec::Expectations::ExpectationNotMetError` if not matched

```ruby
job.expect_headers(priority: "high", batch_id: "batch-42")
  .and_complete
```

### Terminal Methods

These methods complete the job lifecycle. All return `self` for chaining.

#### `mark_completed(variables = {})`

Completes the job successfully with optional output variables.

**Alias:** `and_complete`

**Parameters:**
- `variables` (Hash) - Output variables to merge into process state

**Example:**

```ruby
job.mark_completed(payment_id: "pay-789", charged_amount: 99.99)

# Fluent chaining style
activate_job("process-payment")
  .expect_variables(amount: 99.99)
  .and_complete(payment_id: "pay-789")
```

#### `mark_failed(message = nil, retries: 0)`

Fails the job with an error message and retry count.

**Alias:** `and_fail`

**Parameters:**
- `message` (String, nil) - Error message
- `retries` (Integer) - Number of retries remaining (default: `0`)

**Example:**

```ruby
job.mark_failed("Payment gateway timeout", retries: 2)

# Fluent style
activate_job("external-api-call")
  .and_fail("Service unavailable", retries: 3)
```

#### `throw_error_event(code, message = nil)`

Throws a BPMN error event that can be caught by error boundary events.

**Alias:** `and_throw_error_event`

**Parameters:**
- `code` (String) - BPMN error code
- `message` (String, nil) - Error message

**Example:**

```ruby
job.throw_error_event("VALIDATION_FAILED", "Invalid order data")

# Fluent style
activate_job("validate-order")
  .and_throw_error_event("INVALID_ITEMS", "Item count mismatch")
```

#### `update_retries(count)`

Updates the job's retry count without completing or failing it.

**Parameters:**
- `count` (Integer) - New retry count

**Example:**

```ruby
job.update_retries(5)
```

## RSpec Matchers

### `have_received_variables`

Matches activated jobs with expected variable values.

**Example:**

```ruby
job = activate_job("my-task")
expect(job).to have_received_variables(order_id: "123")
expect(job).to have_received_variables("order_id" => "123", "total" => 99.99)
```

### `have_received_headers`

Matches activated jobs with expected header values.

**Example:**

```ruby
job = activate_job("my-task")
expect(job).to have_received_headers(priority: "high")
expect(job).to have_received_headers("workflow_version" => "2")
```

### `have_activated`

Flexible matcher supporting chained expectations and terminal actions. Can be used standalone or with chains.

**Chains:**
- `.with_variables(hash)` - Assert expected variables
- `.with_headers(hash)` - Assert expected headers
- `.and_complete(vars)` - Complete job with output
- `.and_fail(message, retries:)` - Fail job
- `.and_throw_error_event(code, message)` - Throw error

**Examples:**

```ruby
# Basic activation check
job = activate_job("my-task")
expect(job).to have_activated

# With variable assertions
expect(job).to have_activated.with_variables(order_id: "123")

# Complete workflow with chaining
expect(activate_job("process-order"))
  .to have_activated
  .with_variables(order_id: "123", total: 99.99)
  .with_headers(priority: "high")
  .and_complete(processed: true, processed_at: Time.now.iso8601)
```

### `have_available_jobs`

Matcher to check if jobs are available for activation. Primarily used in negated form to verify that no jobs exist.

**Aliases:** `have_an_available_job`

**Example:**

```ruby
# Verify jobs are available
expect { activate_job("process-order") }.to have_available_jobs

# More commonly: verify NO jobs are available (most common usage)
expect { activate_job("process-order") }.not_to have_available_jobs

# Use case: verify signal didn't create instances
client.broadcast_signal("non-existent-signal")
expect { activate_job("process-order") }.not_to have_an_available_job
```

## Complete Workflow Example

Here's a complete example testing an order fulfillment workflow:

```ruby
# spec/workflows/order_fulfillment_spec.rb
require "spec_helper"

RSpec.describe "Order Fulfillment Workflow" do
  let(:bpmn_path) { File.expand_path("../fixtures/order_fulfillment.bpmn", __dir__) }
  let(:process_id) { deploy_process(bpmn_path, uniquify: true)[:process_id] }
  let(:order_id) { SecureRandom.uuid }

  context "when order is approved" do
    it "processes payment and ships order" do
      with_process_instance(process_id, order_id: order_id, items_count: 3) do
        # Verify payment processing job
        expect(activate_job("process-payment"))
          .to have_activated
          .with_variables(order_id: order_id, items_count: 3)
          .and_complete(payment_id: "pay-#{SecureRandom.hex(4)}", amount_charged: 149.99)

        # Verify shipment preparation
        expect(activate_job("prepare-shipment"))
          .to have_activated
          .with_variables(order_id: order_id, payment_id: /^pay-/)
          .and_complete(tracking_number: "TRACK123", carrier: "FedEx")

        # Verify notification sent
        notification_job = activate_job("send-confirmation-email")
        expect(notification_job).to have_received_variables(
          order_id: order_id,
          tracking_number: "TRACK123"
        )
        notification_job.mark_completed(email_sent: true)

        # Assert workflow completed
        assert_process_completed!
      end
    end
  end

  context "when payment fails" do
    it "handles payment error and notifies customer" do
      with_process_instance(process_id, order_id: order_id, items_count: 2) do
        # Payment fails with error event
        activate_job("process-payment")
          .expect_variables(order_id: order_id)
          .and_throw_error_event("PAYMENT_DECLINED", "Insufficient funds")

        # Error boundary catches and triggers notification
        expect(activate_job("send-payment-failed-email"))
          .to have_activated
          .with_variables(order_id: order_id)
          .and_complete

        assert_process_completed!
      end
    end
  end

  context "when shipment needs approval" do
    it "waits for approval message" do
      correlation_key = "approval-#{order_id}"

      with_process_instance(process_id, order_id: order_id, correlation_id: correlation_key) do
        # Complete initial jobs
        activate_job("process-payment").and_complete(payment_id: "pay-123")
        activate_job("check-shipment-requirements")
          .and_complete(requires_approval: true)

        # Process waits at message intermediate catch event
        # Publish approval message
        publish_message(
          "shipment-approved",
          correlation_key: correlation_key,
          variables: { approved_by: "manager@example.com", approved_at: Time.now.iso8601 }
        )

        # Verify shipment proceeds
        expect(activate_job("prepare-shipment"))
          .to have_activated
          .with_variables(
            approved_by: "manager@example.com",
            requires_approval: true
          )
          .and_complete(tracking_number: "TRACK456")

        activate_job("send-confirmation-email").and_complete

        assert_process_completed!
      end
    end
  end
end
```

## Composing Shared Workflow Contexts

For complex workflows with many test scenarios, extract common setup into shared contexts:

```ruby
# spec/support/workflow_contexts.rb
RSpec.shared_context "deployed order workflow" do
  let(:bpmn_path) { File.expand_path("../../integration/fixtures/order_fulfillment.bpmn", __dir__) }
  let(:process_id) { deploy_process(bpmn_path, uniquify: true)[:process_id] }
  let(:order_id) { SecureRandom.uuid }
  let(:base_variables) { { order_id: order_id, customer_id: "cust-123" } }

  def complete_payment_step(payment_status: "success")
    activate_job("process-payment")
      .expect_variables(order_id: order_id)
      .and_complete(
        payment_id: "pay-#{SecureRandom.hex(4)}",
        payment_status: payment_status
      )
  end

  def complete_shipment_step
    activate_job("prepare-shipment")
      .and_complete(tracking_number: "TRACK#{rand(1000..9999)}")
  end
end

# Use in specs
RSpec.describe "Order edge cases" do
  include_context "deployed order workflow"

  it "handles partial shipments" do
    with_process_instance(process_id, base_variables.merge(partial_shipment: true)) do
      complete_payment_step
      complete_shipment_step
      # Additional steps...
      assert_process_completed!
    end
  end
end
```

## Testing Best Practices

### 1. Use Unique Process IDs for Isolation

Deploy processes with unique IDs when tests might interfere:

```ruby
# Good: Each test gets isolated process
let(:process_id) { deploy_process(bpmn_path, uniquify: true)[:process_id] }

# Avoid: Shared process might cause cross-test pollution
before(:all) { @process_id = deploy_process(bpmn_path)[:process_id] }
```

### 2. Always Clean Up Process Instances

Use `with_process_instance` which automatically cancels instances:

```ruby
# Good: Automatic cleanup
with_process_instance(process_id) do |key|
  # test code
end

# Avoid: Manual instance management
key = create_instance(process_id)
# ... test code ...
cancel_instance(key) # Easy to forget in error paths
```

### 3. Verify Job Variables Before Completing

Assert expected inputs before completing jobs:

```ruby
# Good: Verify then complete
job = activate_job("send-email")
expect(job).to have_received_variables(
  recipient: "user@example.com",
  template: "order_confirmation"
)
job.mark_completed(sent_at: Time.now.iso8601)

# Also Good: fluent style
activate_job("send-email")
  .expect_variables(recipient: "user@example.com")
  .and_complete(sent_at: Time.now.iso8601)
```

## Troubleshooting

If you are running the entire Camunda Platform, you can debug your workflow by checking the Operate UI to inspect process state. The `last_process_instance_key` helper can be used to help you find the process instance in question.

### "Zeebe is not running"

Ensure Zeebe is started **and healthy** before running your tests.

### "No job of type 'my-task' available"

Common causes:
- Process instance hasn't reached that task yet
- Job type name doesn't match BPMN definition
- Job already activated by another worker
- Process completed or failed before reaching task

### "Process instance still running"

When `assert_process_completed!` fails:
- Verify all jobs were activated and completed
- Check for message intermediate catch events waiting for messages
- Look for timer events that haven't fired
- Use `last_process_instance_key` to find instance in Operate

### Variables Not Available in Job

Ensure variables are:
- Set in start variables: `with_process_instance(id, my_var: "value")`
- Returned from previous job: `job.mark_completed(output_var: "value")`
- Correctly I/O-mapped on each service task
