## [Unreleased]

## [0.1.0] - 2025-12-29

Initial public release with foundational components for testing BPMN workflows.

### Added

- **Testing module** (`Busybee::Testing`) - RSpec helpers and matchers for testing BPMN workflows against Zeebe:
  - `deploy_process` - Deploy BPMN files with optional unique IDs for test isolation
  - `with_process_instance` - Create process instances with automatic cleanup
  - `activate_job` / `activate_jobs` - Activate jobs for assertions
  - `publish_message` - Trigger message catch events
  - `set_variables` - Update process variables
  - `assert_process_completed!` - Verify workflow completion
  - `ActivatedJob` fluent API with `expect_variables`, `expect_headers`, `and_complete`, `and_fail`, `and_throw_error_event`
  - RSpec matchers: `have_activated`, `have_received_variables`, `have_received_headers`

- **GRPC layer** (`Busybee::GRPC`) - Generated protocol buffer classes from the Zeebe 8.8 proto definition for direct Zeebe API access

## [0.0.1] - 2025-12-03

- Initial development, not for release
