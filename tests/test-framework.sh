#!/bin/bash
# test-framework.sh - Testing framework for NGINX Dev Gateway

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Test output control
VERBOSE="${VERBOSE:-0}"
QUIET="${QUIET:-0}"

# Test namespace (isolated for testing)
TEST_NAMESPACE="${TEST_NAMESPACE:-test-nginx-gateway-$(date +%s)}"
TEST_CLEANUP="${TEST_CLEANUP:-1}"

# Test result tracking
declare -A TEST_RESULTS
declare -A TEST_TIMES

# Logging functions for tests
log_info() {
    echo -e "${CYAN}[INFO]${NC} $@"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $@"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $@"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $@"
}

# Start test suite
start_test_suite() {
    local suite_name="$1"
    echo -e "\n${BLUE}═══ Test Suite: $suite_name ═══${NC}"
    SUITE_START_TIME=$(date +%s)
}

# End test suite
end_test_suite() {
    local suite_name="$1"
    local suite_end_time=$(date +%s)
    local suite_duration=$((suite_end_time - SUITE_START_TIME))

    echo -e "\n${BLUE}═══ Suite Summary: $suite_name ═══${NC}"
    echo "Duration: ${suite_duration}s"
    echo "Tests run: $TESTS_RUN"
    echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
    [ $TESTS_FAILED -gt 0 ] && echo -e "${RED}Failed: $TESTS_FAILED${NC}"
    [ $TESTS_SKIPPED -gt 0 ] && echo -e "${YELLOW}Skipped: $TESTS_SKIPPED${NC}"

    # Show failed tests
    if [ $TESTS_FAILED -gt 0 ]; then
        echo -e "\n${RED}Failed Tests:${NC}"
        for test_name in "${!TEST_RESULTS[@]}"; do
            if [ "${TEST_RESULTS[$test_name]}" = "FAILED" ]; then
                echo "  - $test_name"
            fi
        done
    fi

    # Return non-zero if any tests failed
    [ $TESTS_FAILED -eq 0 ]
}

# Run a test
run_test() {
    local test_name="$1"
    local test_function="$2"

    TESTS_RUN=$((TESTS_RUN + 1))
    local test_start=$(date +%s%N)

    if [ "$QUIET" -eq 0 ]; then
        echo -n "  Testing: $test_name ... "
    fi

    # Capture test output
    local output_file="/tmp/test-output-$$.txt"
    local error_file="/tmp/test-error-$$.txt"

    # Run test function
    if $test_function > "$output_file" 2> "$error_file"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        TEST_RESULTS["$test_name"]="PASSED"
        [ "$QUIET" -eq 0 ] && echo -e "${GREEN}✓${NC}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        TEST_RESULTS["$test_name"]="FAILED"
        [ "$QUIET" -eq 0 ] && echo -e "${RED}✗${NC}"

        # Show error details if verbose
        if [ "$VERBOSE" -eq 1 ]; then
            echo -e "${RED}    Error output:${NC}"
            cat "$error_file" | sed 's/^/      /'
            if [ -s "$output_file" ]; then
                echo -e "${RED}    Standard output:${NC}"
                cat "$output_file" | sed 's/^/      /'
            fi
        fi
    fi

    # Calculate test duration
    local test_end=$(date +%s%N)
    local test_duration=$(( (test_end - test_start) / 1000000 ))
    TEST_TIMES["$test_name"]=$test_duration

    [ "$VERBOSE" -eq 1 ] && echo "    Duration: ${test_duration}ms"

    # Cleanup
    rm -f "$output_file" "$error_file"
}

# Skip a test
skip_test() {
    local test_name="$1"
    local reason="${2:-No reason given}"

    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    TEST_RESULTS["$test_name"]="SKIPPED"

    if [ "$QUIET" -eq 0 ]; then
        echo -e "  Testing: $test_name ... ${YELLOW}⊘ SKIPPED${NC} ($reason)"
    fi
}

# Assert functions
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Values should be equal}"

    if [ "$expected" != "$actual" ]; then
        echo "Assertion failed: $message" >&2
        echo "  Expected: '$expected'" >&2
        echo "  Actual:   '$actual'" >&2
        return 1
    fi
    return 0
}

assert_not_equals() {
    local unexpected="$1"
    local actual="$2"
    local message="${3:-Values should not be equal}"

    if [ "$unexpected" = "$actual" ]; then
        echo "Assertion failed: $message" >&2
        echo "  Unexpected: '$unexpected'" >&2
        echo "  Actual:     '$actual'" >&2
        return 1
    fi
    return 0
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String should contain substring}"

    if [[ ! "$haystack" == *"$needle"* ]]; then
        echo "Assertion failed: $message" >&2
        echo "  String: '$haystack'" >&2
        echo "  Should contain: '$needle'" >&2
        return 1
    fi
    return 0
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String should not contain substring}"

    if [[ "$haystack" == *"$needle"* ]]; then
        echo "Assertion failed: $message" >&2
        echo "  String: '$haystack'" >&2
        echo "  Should not contain: '$needle'" >&2
        return 1
    fi
    return 0
}

assert_exit_code() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Exit code should match}"

    if [ "$expected" -ne "$actual" ]; then
        echo "Assertion failed: $message" >&2
        echo "  Expected exit code: $expected" >&2
        echo "  Actual exit code:   $actual" >&2
        return 1
    fi
    return 0
}

assert_file_exists() {
    local file="$1"
    local message="${2:-File should exist}"

    if [ ! -f "$file" ]; then
        echo "Assertion failed: $message" >&2
        echo "  File not found: '$file'" >&2
        return 1
    fi
    return 0
}

assert_file_not_exists() {
    local file="$1"
    local message="${2:-File should not exist}"

    if [ -f "$file" ]; then
        echo "Assertion failed: $message" >&2
        echo "  File exists: '$file'" >&2
        return 1
    fi
    return 0
}

assert_command_exists() {
    local command="$1"
    local message="${2:-Command should exist}"

    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Assertion failed: $message" >&2
        echo "  Command not found: '$command'" >&2
        return 1
    fi
    return 0
}

# Mock functions
mock_command() {
    local command="$1"
    local mock_output="$2"
    local mock_exit_code="${3:-0}"

    # Create mock function
    eval "$command() {
        echo '$mock_output'
        return $mock_exit_code
    }"

    export -f "$command"
}

unmock_command() {
    local command="$1"
    unset -f "$command"
}

# Setup and teardown
setup_test_environment() {
    # Create test namespace if testing in Kubernetes
    if [ -n "$TEST_KUBERNETES" ]; then
        kubectl create namespace "$TEST_NAMESPACE" 2>/dev/null || true
    fi

    # Create temp directory for test files
    export TEST_TEMP_DIR="/tmp/nginx-gateway-tests-$$"
    mkdir -p "$TEST_TEMP_DIR"

    # Set test environment variables
    export NAMESPACE="$TEST_NAMESPACE"
    # Only set REGISTRY if not already set
    export REGISTRY="${REGISTRY:-test-registry.local}"
    export IMAGE_NAME="${IMAGE_NAME:-nginx-dev-gateway-test}"
    export IMAGE_TAG="${IMAGE_TAG:-test-$(date +%s)}"
}

teardown_test_environment() {
    # Clean up test namespace if requested
    if [ "$TEST_CLEANUP" -eq 1 ] && [ -n "$TEST_KUBERNETES" ]; then
        kubectl delete namespace "$TEST_NAMESPACE" --ignore-not-found=true 2>/dev/null || true
    fi

    # Clean up temp files
    rm -rf "$TEST_TEMP_DIR"

    # Unset test environment variables
    unset NAMESPACE REGISTRY IMAGE_NAME IMAGE_TAG TEST_TEMP_DIR
}

# Generate test report
generate_test_report() {
    local report_file="${1:-tests/reports/test-report-$(date +%Y%m%d-%H%M%S).json}"
    local report_dir=$(dirname "$report_file")

    mkdir -p "$report_dir"

    cat > "$report_file" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "summary": {
        "total": $TESTS_RUN,
        "passed": $TESTS_PASSED,
        "failed": $TESTS_FAILED,
        "skipped": $TESTS_SKIPPED,
        "success_rate": $(echo "scale=2; $TESTS_PASSED * 100 / $TESTS_RUN" | bc)
    },
    "tests": [
EOF

    local first=1
    for test_name in "${!TEST_RESULTS[@]}"; do
        [ $first -eq 0 ] && echo "," >> "$report_file"
        first=0

        cat >> "$report_file" << EOF
        {
            "name": "$test_name",
            "status": "${TEST_RESULTS[$test_name]}",
            "duration_ms": ${TEST_TIMES[$test_name]:-0}
        }
EOF
    done

    cat >> "$report_file" << EOF
    ]
}
EOF

    echo "Test report generated: $report_file"
}

# Helper function to strip ANSI color codes
strip_colors() {
    echo "$1" | sed -E 's/\\033\[[0-9;]+m//g' | sed -E $'s/\x1b\[[0-9;]+m//g'
}

# Assert with color stripping
assert_contains_stripped() {
    local haystack="$(strip_colors "$1")"
    local needle="$2"
    local message="${3:-String should contain substring (colors stripped)}"

    if [[ ! "$haystack" == *"$needle"* ]]; then
        echo "Assertion failed: $message" >&2
        echo "  String (stripped): '$haystack'" >&2
        echo "  Should contain: '$needle'" >&2
        return 1
    fi
    return 0
}

# Export functions for use in test scripts
export -f run_test skip_test
export -f assert_equals assert_not_equals assert_contains assert_not_contains
export -f assert_exit_code assert_file_exists assert_file_not_exists assert_command_exists
export -f assert_contains_stripped strip_colors
export -f mock_command unmock_command
export -f setup_test_environment teardown_test_environment