#!/bin/bash
# run-tests.sh - Main test runner for NGINX Dev Gateway

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source test framework
source "$SCRIPT_DIR/test-framework.sh"

# Test configuration
TEST_TYPE="${1:-all}"
VERBOSE="${VERBOSE:-0}"
QUIET="${QUIET:-0}"
GENERATE_REPORT="${GENERATE_REPORT:-1}"

# Colors for output
readonly BOLD='\033[1m'

# Show usage
show_usage() {
    cat << EOF
NGINX Dev Gateway Test Runner

Usage: $0 [TEST_TYPE] [OPTIONS]

TEST TYPES:
    all         Run all tests (default)
    unit        Run unit tests only
    integration Run integration tests only
    quick       Run quick smoke tests
    specific    Run specific test file (provide path)

OPTIONS:
    VERBOSE=1   Show detailed test output
    QUIET=1     Suppress most output
    GENERATE_REPORT=0  Skip report generation

EXAMPLES:
    # Run all tests
    $0

    # Run unit tests only
    $0 unit

    # Run with verbose output
    VERBOSE=1 $0

    # Run specific test file
    $0 specific tests/unit/test-validation.sh

EOF
}

# Run unit tests
run_unit_tests() {
    echo -e "\n${BOLD}${BLUE}════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}     UNIT TESTS${NC}"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════${NC}"

    local unit_dir="$SCRIPT_DIR/unit"
    local total_tests=0
    local passed_tests=0
    local failed_tests=0

    if [ -d "$unit_dir" ]; then
        for test_file in "$unit_dir"/test-*.sh; do
            if [ -f "$test_file" ]; then
                echo -e "\n${BOLD}Running: $(basename $test_file)${NC}"
                if bash "$test_file"; then
                    passed_tests=$((passed_tests + 1))
                else
                    failed_tests=$((failed_tests + 1))
                fi
                total_tests=$((total_tests + 1))
            fi
        done
    else
        echo "No unit tests found in $unit_dir"
    fi

    echo -e "\n${BOLD}Unit Test Summary:${NC}"
    echo "Total: $total_tests, Passed: $passed_tests, Failed: $failed_tests"

    return $failed_tests
}

# Run integration tests
run_integration_tests() {
    echo -e "\n${BOLD}${BLUE}════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}     INTEGRATION TESTS${NC}"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════${NC}"

    local integration_dir="$SCRIPT_DIR/integration"
    local total_tests=0
    local passed_tests=0
    local failed_tests=0

    if [ -d "$integration_dir" ]; then
        for test_file in "$integration_dir"/test-*.sh; do
            if [ -f "$test_file" ]; then
                echo -e "\n${BOLD}Running: $(basename $test_file)${NC}"
                if bash "$test_file"; then
                    passed_tests=$((passed_tests + 1))
                else
                    failed_tests=$((failed_tests + 1))
                fi
                total_tests=$((total_tests + 1))
            fi
        done
    else
        echo "No integration tests found in $integration_dir"
    fi

    echo -e "\n${BOLD}Integration Test Summary:${NC}"
    echo "Total: $total_tests, Passed: $passed_tests, Failed: $failed_tests"

    return $failed_tests
}

# Run quick smoke tests
run_quick_tests() {
    echo -e "\n${BOLD}${BLUE}════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}     QUICK SMOKE TESTS${NC}"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════${NC}"

    start_test_suite "Quick Smoke Tests"

    # Test that manage.sh exists and is executable
    run_test "manage.sh exists" test_manage_exists
    run_test "manage.sh is executable" test_manage_executable
    run_test "Libraries exist" test_libraries_exist
    run_test "Help command works" test_help_works
    run_test "Version command works" test_version_works

    end_test_suite "Quick Smoke Tests"
}

# Quick test functions
test_manage_exists() {
    assert_file_exists "$PROJECT_ROOT/manage.sh"
}

test_manage_executable() {
    [ -x "$PROJECT_ROOT/manage.sh" ]
}

test_libraries_exist() {
    assert_file_exists "$PROJECT_ROOT/scripts/lib/common.sh"
    assert_file_exists "$PROJECT_ROOT/scripts/lib/docker.sh"
    assert_file_exists "$PROJECT_ROOT/scripts/lib/k8s.sh"
    assert_file_exists "$PROJECT_ROOT/scripts/lib/config.sh"
    assert_file_exists "$PROJECT_ROOT/scripts/lib/validation.sh"
}

test_help_works() {
    "$PROJECT_ROOT/manage.sh" help >/dev/null 2>&1
}

test_version_works() {
    "$PROJECT_ROOT/manage.sh" version >/dev/null 2>&1
}

# Run specific test file
run_specific_test() {
    local test_file="$1"

    if [ ! -f "$test_file" ]; then
        echo "Error: Test file not found: $test_file"
        return 1
    fi

    echo -e "\n${BOLD}Running specific test: $test_file${NC}"
    bash "$test_file"
}

# Main execution
main() {
    local exit_code=0

    # Show header
    echo -e "${BOLD}${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║   NGINX Dev Gateway Test Suite        ║${NC}"
    echo -e "${BOLD}${GREEN}╚════════════════════════════════════════╝${NC}"
    echo -e "Test Type: ${BOLD}$TEST_TYPE${NC}"
    echo -e "Project Root: $PROJECT_ROOT"
    echo -e "Timestamp: $(date)"
    echo

    # Setup test environment
    setup_test_environment

    # Run appropriate tests
    case "$TEST_TYPE" in
        all)
            run_quick_tests
            quick_exit=$?

            run_unit_tests
            unit_exit=$?

            run_integration_tests
            integration_exit=$?

            exit_code=$((quick_exit + unit_exit + integration_exit))
            ;;
        unit)
            run_unit_tests
            exit_code=$?
            ;;
        integration)
            run_integration_tests
            exit_code=$?
            ;;
        quick)
            run_quick_tests
            exit_code=$?
            ;;
        specific)
            if [ -n "$2" ]; then
                run_specific_test "$2"
                exit_code=$?
            else
                echo "Error: Please provide path to test file"
                show_usage
                exit 1
            fi
            ;;
        help|--help|-h)
            show_usage
            exit 0
            ;;
        *)
            echo "Error: Unknown test type: $TEST_TYPE"
            show_usage
            exit 1
            ;;
    esac

    # Generate report if requested
    if [ "$GENERATE_REPORT" -eq 1 ] && [ "$TEST_TYPE" != "help" ]; then
        generate_test_report
    fi

    # Cleanup test environment
    teardown_test_environment

    # Show final summary
    echo -e "\n${BOLD}${GREEN}════════════════════════════════════════${NC}"
    if [ $exit_code -eq 0 ]; then
        echo -e "${BOLD}${GREEN}     ALL TESTS PASSED! ✓${NC}"
    else
        echo -e "${BOLD}${RED}     SOME TESTS FAILED ✗${NC}"
    fi
    echo -e "${BOLD}${GREEN}════════════════════════════════════════${NC}"

    exit $exit_code
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi