# NGINX Dev Gateway Test Suite

Comprehensive testing framework for the NGINX Dev Gateway, including unit, integration, and end-to-end tests.

## Test Structure

```
tests/
├── test-framework.sh      # Core testing framework with assertions
├── run-tests.sh           # Main test runner
├── unit/                  # Unit tests
│   ├── test-manage-commands.sh
│   └── test-validation.sh
└── integration/           # Integration tests
    ├── test-gateway-routing.sh
    ├── test-docker-container.sh
    └── test-e2e-deployment.sh
```

## Running Tests

### Quick Smoke Tests
```bash
# Run basic functionality checks
./tests/run-tests.sh quick
```

### Unit Tests
```bash
# Test management script and validation functions
./tests/run-tests.sh unit
```

### Integration Tests
```bash
# Test Docker container and Kubernetes deployment
./tests/run-tests.sh integration
```

### All Tests
```bash
# Run complete test suite
./tests/run-tests.sh all
```

### Specific Test File
```bash
# Run a specific test file
./tests/run-tests.sh specific tests/unit/test-validation.sh
```

## Test Framework Features

### Assertions
- `assert_equals` - Check values are equal
- `assert_not_equals` - Check values are not equal
- `assert_contains` - Check string contains substring
- `assert_contains_stripped` - Check with ANSI colors stripped
- `assert_exit_code` - Check command exit code
- `assert_file_exists` - Check file exists
- `assert_command_exists` - Check command is available

### Test Control
- `run_test` - Execute a test function
- `skip_test` - Skip a test with reason
- `mock_command` - Create command mock for testing
- `unmock_command` - Remove command mock

### Environment Variables
- `NAMESPACE` - Kubernetes namespace (required for most tests)
- `VERBOSE=1` - Show detailed test output
- `QUIET=1` - Suppress most output
- `GENERATE_REPORT=0` - Skip JSON report generation

## Test Coverage

### Unit Tests (17 tests)
- **Management Commands** (15/17 passing)
  - Help and version commands
  - Namespace handling
  - Command existence
  - Option parsing

- **Validation Functions** (7/10 passing)
  - YAML validation
  - Route configuration validation
  - Conflict detection
  - Version comparison

### Integration Tests

#### Docker Container Tests (8/8 passing)
- Container starts successfully
- Runs as non-root user
- Health endpoint accessible
- Environment variable substitution
- Nginx config validity
- Custom routes loading
- Resource limits
- Signal handling

#### Gateway Routing Tests
- Health endpoint
- Route configuration
- Proxy headers
- Nginx processes
- Security context
- Environment variables
- WebSocket support
- Port accessibility

#### E2E Deployment Tests
- Kubernetes deployment
- Pod readiness
- Service endpoints
- ConfigMap updates
- Scaling operations
- Resource limits
- Security contexts

## Test Results

### Current Status
- **Quick Tests**: ✅ All 5 passing
- **Unit Tests**: ⚠️ 22/27 passing (5 failures due to test environment)
- **Docker Tests**: ✅ All 8 passing
- **K8s Tests**: ⚠️ Requires active cluster with image in registry

### Known Issues
1. **Color Code Handling**: Some tests fail when comparing colored output
   - Fixed with `assert_contains_stripped` helper
2. **Readonly Variables**: Warnings when sourcing libraries multiple times
   - Non-critical, doesn't affect functionality
3. **E2E Tests**: Require image pushed to registry
   - Works with local Docker tests

## Test Reports

JSON reports are generated in `tests/reports/` with test results:
```json
{
  "timestamp": "2025-09-23T18:15:48",
  "summary": {
    "total": 5,
    "passed": 5,
    "failed": 0,
    "skipped": 0,
    "success_rate": 100.00
  },
  "tests": [...]
}
```

## Adding New Tests

1. Create test file in appropriate directory:
```bash
#!/bin/bash
source "$SCRIPT_DIR/../test-framework.sh"

test_my_feature() {
    # Test implementation
    assert_equals "expected" "actual"
}

main() {
    start_test_suite "My Feature Tests"
    run_test "Feature works" test_my_feature
    end_test_suite "My Feature Tests"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
```

2. Make executable:
```bash
chmod +x tests/unit/test-my-feature.sh
```

3. Run tests:
```bash
./tests/run-tests.sh specific tests/unit/test-my-feature.sh
```

## CI/CD Integration

For CI/CD pipelines:
```yaml
# Example GitHub Actions
- name: Run Tests
  run: |
    export NAMESPACE=ci-test
    ./tests/run-tests.sh quick
    ./tests/run-tests.sh unit
```

## Troubleshooting

### Tests Failing with Color Codes
Use `assert_contains_stripped` instead of `assert_contains` for colored output.

### Docker Tests Fail
Ensure Docker daemon is running and you have permissions.

### Kubernetes Tests Fail
- Ensure kubectl is configured
- Image must be in accessible registry
- Namespace must exist or be creatable

### Timeout Issues
Increase timeout for slow operations:
```bash
TIMEOUT=300 ./tests/run-tests.sh integration
```