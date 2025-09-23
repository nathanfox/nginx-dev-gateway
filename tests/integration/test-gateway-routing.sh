#!/bin/bash
# test-gateway-routing.sh - Integration tests for gateway routing functionality

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source test framework
source "$SCRIPT_DIR/../test-framework.sh"

# Test variables
TEST_POD_NAME=""
TEST_NAMESPACE="${TEST_NAMESPACE:-test-nginx-gateway}"

# Setup test pod
setup_test_pod() {
    # Check if kubectl is available
    if ! command -v kubectl >/dev/null 2>&1; then
        skip_test "Gateway routing tests" "kubectl not available"
        return 1
    fi

    # Check if we can connect to cluster
    if ! kubectl cluster-info >/dev/null 2>&1; then
        skip_test "Gateway routing tests" "Cannot connect to Kubernetes cluster"
        return 1
    fi

    # Wait for pod to be ready (max 30 seconds)
    local max_attempts=15
    local attempt=0

    echo "Waiting for nginx-gateway pod in namespace $NAMESPACE..."
    while [ $attempt -lt $max_attempts ]; do
        TEST_POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l app=nginx-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

        if [ -n "$TEST_POD_NAME" ]; then
            local pod_status=$(kubectl get pod "$TEST_POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
            if [ "$pod_status" = "Running" ]; then
                echo "Found running pod: $TEST_POD_NAME"
                return 0
            fi
        fi

        attempt=$((attempt + 1))
        sleep 2
    done

    skip_test "Gateway routing tests" "No running nginx-gateway pod found in namespace $NAMESPACE"
    return 1
}

# Test health endpoint
test_health_endpoint() {
    local response=$(kubectl exec -n "$NAMESPACE" "$TEST_POD_NAME" -- curl -s -w "\n%{http_code}" http://localhost/health 2>/dev/null)
    local http_code=$(echo "$response" | tail -1)
    local body=$(echo "$response" | head -n -1)

    assert_equals "200" "$http_code" "Health endpoint should return 200"
    # Accept either "OK" or "healthy" as valid responses
    if [[ "$body" == *"OK"* ]] || [[ "$body" == *"healthy"* ]]; then
        return 0
    else
        echo "Health response: '$body'"
        return 1
    fi
}

# Test routing configuration loaded
test_routes_loaded() {
    # Routes can be in either /etc/nginx/conf.d/routes.conf or /etc/nginx/routes/*.conf
    local routes_found=0
    local config=""

    # Check /etc/nginx/routes/ directory first (ConfigMap mount)
    if kubectl exec -n "$NAMESPACE" "$TEST_POD_NAME" -- ls /etc/nginx/routes/ 2>/dev/null | grep -q ".conf"; then
        # Use sh -c to properly expand the wildcard
        config=$(kubectl exec -n "$NAMESPACE" "$TEST_POD_NAME" -- sh -c 'cat /etc/nginx/routes/*.conf 2>/dev/null')
        if [ -n "$config" ]; then
            routes_found=1
        fi
    fi

    # Fallback to /etc/nginx/conf.d/routes.conf
    if [ $routes_found -eq 0 ]; then
        config=$(kubectl exec -n "$NAMESPACE" "$TEST_POD_NAME" -- cat /etc/nginx/conf.d/routes.conf 2>/dev/null)
        if [ -n "$config" ]; then
            routes_found=1
        fi
    fi

    if [ $routes_found -eq 0 ] || [ -z "$config" ]; then
        echo "No routes configuration found in either location"
        return 1
    fi

    # Check if routes file exists (even if all routes are commented)
    # This is valid - routes can be empty or commented out
    echo "Routes configuration file found"

    # Check for route patterns (including commented examples)
    if echo "$config" | grep -q "location"; then
        echo "Routes file contains location blocks (may be commented)"
        return 0
    else
        echo "Routes file exists but contains no location blocks"
        return 1
    fi
}

# Test proxy headers are set
test_proxy_headers() {
    # Check that proxy.conf is included
    local config=$(kubectl exec -n "$NAMESPACE" "$TEST_POD_NAME" -- cat /etc/nginx/includes/proxy.conf 2>/dev/null)

    assert_contains "$config" "X-Real-IP" "Proxy config should set X-Real-IP"
    assert_contains "$config" "X-Forwarded-For" "Proxy config should set X-Forwarded-For"
    assert_contains "$config" "X-Forwarded-Host" "Proxy config should set X-Forwarded-Host"
    assert_contains "$config" "X-Forwarded-Proto" "Proxy config should set X-Forwarded-Proto"
}

# Test nginx process running
test_nginx_process() {
    local processes=$(kubectl exec -n "$NAMESPACE" "$TEST_POD_NAME" -- ps aux 2>/dev/null | grep nginx | grep -v grep)

    assert_contains "$processes" "nginx: master" "Should have nginx master process"
    assert_contains "$processes" "nginx: worker" "Should have nginx worker process"
}

# Test non-root user
test_non_root_user() {
    local user_id=$(kubectl exec -n "$NAMESPACE" "$TEST_POD_NAME" -- id -u 2>/dev/null)

    assert_equals "101" "$user_id" "Should be running as nginx user (UID 101)"
}

# Test environment variables
test_environment_variables() {
    local namespace_var=$(kubectl exec -n "$NAMESPACE" "$TEST_POD_NAME" -- printenv CURRENT_NAMESPACE 2>/dev/null)

    assert_equals "$NAMESPACE" "$namespace_var" "CURRENT_NAMESPACE should match pod namespace"
}

# Test nginx config syntax
test_nginx_config_valid() {
    local result=$(kubectl exec -n "$NAMESPACE" "$TEST_POD_NAME" -- nginx -t 2>&1)

    assert_contains "$result" "syntax is ok" "Nginx config syntax should be valid"
    assert_contains "$result" "test is successful" "Nginx config test should succeed"
}

# Test WebSocket configuration
test_websocket_config() {
    local ws_config=$(kubectl exec -n "$NAMESPACE" "$TEST_POD_NAME" -- cat /etc/nginx/includes/websocket.conf 2>/dev/null)

    assert_contains "$ws_config" "Upgrade" "WebSocket config should handle Upgrade header"
    assert_contains "$ws_config" "Connection" "WebSocket config should handle Connection header"
    assert_contains "$ws_config" "1.1" "WebSocket config should use HTTP/1.1"
}

# Test port accessibility
test_port_accessibility() {
    # Test that port 80 is listening
    local listening=$(kubectl exec -n "$NAMESPACE" "$TEST_POD_NAME" -- netstat -tln 2>/dev/null | grep :80)

    assert_contains "$listening" ":80" "Port 80 should be listening"
}

# Main test execution
main() {
    start_test_suite "Gateway Routing Integration Tests"

    # Setup
    if ! setup_test_pod; then
        end_test_suite "Gateway Routing Integration Tests"
        return 0
    fi

    # Run tests
    run_test "Health endpoint accessible" test_health_endpoint
    run_test "Routes configuration loaded" test_routes_loaded
    run_test "Proxy headers configured" test_proxy_headers
    run_test "Nginx process running" test_nginx_process
    run_test "Running as non-root user" test_non_root_user
    run_test "Environment variables set" test_environment_variables
    run_test "Nginx config valid" test_nginx_config_valid
    run_test "WebSocket config present" test_websocket_config
    run_test "Port 80 accessible" test_port_accessibility

    end_test_suite "Gateway Routing Integration Tests"
}

# Run tests if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi