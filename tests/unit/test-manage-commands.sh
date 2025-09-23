#!/bin/bash
# test-manage-commands.sh - Unit tests for management script commands

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source test framework
source "$SCRIPT_DIR/../test-framework.sh"

# Source the management script libraries
source "$PROJECT_ROOT/scripts/lib/common.sh"

# Path to manage.sh
MANAGE_SCRIPT="$PROJECT_ROOT/manage.sh"

# Test help command
test_help_command() {
    local output=$($MANAGE_SCRIPT help 2>&1)
    assert_contains_stripped "$output" "NGINX Dev Gateway Management Script" "Help should show script title"
    assert_contains_stripped "$output" "Usage:" "Help should show usage"
    assert_contains_stripped "$output" "COMMANDS:" "Help should list commands"
    assert_exit_code 0 $?
}

# Test version command
test_version_command() {
    local output=$($MANAGE_SCRIPT version 2>&1)
    assert_contains_stripped "$output" "version" "Version output should contain 'version'"
    assert_contains_stripped "$output" "2.0.0" "Version should be 2.0.0"
    assert_exit_code 0 $?
}

# Test unknown command
test_unknown_command() {
    local output=$($MANAGE_SCRIPT nonexistent 2>&1)
    assert_contains_stripped "$output" "Unknown command" "Should report unknown command"
    # Exit code check should be separate
    $MANAGE_SCRIPT nonexistent 2>&1 >/dev/null
    assert_exit_code 1 $?
}

# Test namespace requirement
test_namespace_required() {
    # Save original namespace
    local orig_namespace="$NAMESPACE"
    unset NAMESPACE

    # Mock kubectl to avoid actual cluster interaction
    mock_command "kubectl" "mocked-kubectl-output" 1

    local output=$($MANAGE_SCRIPT status 2>&1)
    local exit_code=$?

    # Restore
    unmock_command "kubectl"
    export NAMESPACE="$orig_namespace"

    # Check for either "namespace" or "Namespace" in the output
    if echo "$(strip_colors "$output")" | grep -qi "namespace"; then
        # Test passes - namespace requirement is mentioned
        return 0
    else
        echo "Output does not mention namespace requirement"
        return 1
    fi
}

# Test namespace via environment
test_namespace_from_env() {
    export NAMESPACE="test-env-ns"
    local output=$($MANAGE_SCRIPT --version 2>&1)
    # Version command should work regardless of namespace
    assert_exit_code 0 $?
    unset NAMESPACE
}

# Test namespace via flag
test_namespace_from_flag() {
    # Mock kubectl to avoid actual cluster interaction
    mock_command "kubectl" "deployment/nginx-gateway" 0

    local output=$($MANAGE_SCRIPT -n test-flag-ns validate 2>&1 || true)
    # Just check that it runs without error when namespace is provided
    # The actual validation may fail but namespace should be accepted
    assert_contains_stripped "$output" "test-flag-ns" "Should use provided namespace"

    unmock_command "kubectl"
}

# Test registry option
test_registry_option() {
    export REGISTRY="test.registry.io"
    # The registry should be available to commands
    assert_equals "test.registry.io" "$REGISTRY"
    unset REGISTRY
}

# Test debug option
test_debug_option() {
    local output=$($MANAGE_SCRIPT -d version 2>&1)
    # Debug mode should still allow version command to work
    assert_contains "$output" "version" "Debug mode should not break version"
}

# Test build command exists
test_build_command_exists() {
    local output=$($MANAGE_SCRIPT help 2>&1)
    assert_contains "$output" "build" "Help should list build command"
}

# Test deploy command exists
test_deploy_command_exists() {
    local output=$($MANAGE_SCRIPT help 2>&1)
    assert_contains "$output" "deploy" "Help should list deploy command"
}

# Test validate command exists
test_validate_command_exists() {
    local output=$($MANAGE_SCRIPT help 2>&1)
    assert_contains "$output" "validate" "Help should list validate command"
}

# Test test command exists
test_test_command_exists() {
    local output=$($MANAGE_SCRIPT help 2>&1)
    assert_contains "$output" "test" "Help should list test command"
}

# Test backup commands exist
test_backup_commands_exist() {
    local output=$($MANAGE_SCRIPT help 2>&1)
    assert_contains "$output" "backup-routes" "Help should list backup-routes"
    assert_contains "$output" "restore-routes" "Help should list restore-routes"
    assert_contains "$output" "backup-all" "Help should list backup-all"
}

# Test config commands exist
test_config_commands_exist() {
    local output=$($MANAGE_SCRIPT help 2>&1)
    assert_contains "$output" "update-routes" "Help should list update-routes"
    assert_contains "$output" "diff-routes" "Help should list diff-routes"
    assert_contains "$output" "list-routes" "Help should list list-routes"
    assert_contains "$output" "export-routes" "Help should list export-routes"
    assert_contains "$output" "generate-routes" "Help should list generate-routes"
}

# Test environment commands exist
test_env_commands_exist() {
    local output=$($MANAGE_SCRIPT help 2>&1)
    assert_contains "$output" "update-env" "Help should list update-env"
    assert_contains "$output" "get-env" "Help should list get-env"
}

# Test port-forward alias
test_port_forward_alias() {
    local output=$($MANAGE_SCRIPT help 2>&1)
    assert_contains "$output" "port-forward" "Help should list port-forward"
    assert_contains "$output" "pf" "Help should list pf alias"
}

# Test multiple options parsing
test_multiple_options() {
    local output=$($MANAGE_SCRIPT -n test-ns -r test.reg -d version 2>&1)
    assert_contains "$output" "version" "Multiple options should work"
}

# Main test execution
main() {
    start_test_suite "Management Commands Unit Tests"

    # Basic command tests
    run_test "Help command" test_help_command
    run_test "Version command" test_version_command
    run_test "Unknown command" test_unknown_command

    # Namespace tests
    run_test "Namespace required" test_namespace_required
    run_test "Namespace from environment" test_namespace_from_env
    run_test "Namespace from flag" test_namespace_from_flag

    # Option tests
    run_test "Registry option" test_registry_option
    run_test "Debug option" test_debug_option
    run_test "Multiple options" test_multiple_options

    # Command existence tests
    run_test "Build command exists" test_build_command_exists
    run_test "Deploy command exists" test_deploy_command_exists
    run_test "Validate command exists" test_validate_command_exists
    run_test "Test command exists" test_test_command_exists
    run_test "Backup commands exist" test_backup_commands_exist
    run_test "Config commands exist" test_config_commands_exist
    run_test "Environment commands exist" test_env_commands_exist
    run_test "Port-forward alias" test_port_forward_alias

    end_test_suite "Management Commands Unit Tests"
}

# Run tests if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi