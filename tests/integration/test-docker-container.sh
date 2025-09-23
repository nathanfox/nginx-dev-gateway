#!/bin/bash
# test-docker-container.sh - Docker container behavior tests

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source test framework
source "$SCRIPT_DIR/../test-framework.sh"

# Test variables
IMAGE_NAME="${IMAGE_NAME:-nginx-dev-gateway}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
TEST_CONTAINER_NAME="test-nginx-gateway-$$"

# Check Docker availability
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        skip_test "Docker container tests" "Docker not available"
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        skip_test "Docker container tests" "Docker daemon not running"
        return 1
    fi

    return 0
}

# Build test image if needed
build_test_image() {
    if ! docker image inspect "${IMAGE_NAME}:${IMAGE_TAG}" >/dev/null 2>&1; then
        echo "Building Docker image ${IMAGE_NAME}:${IMAGE_TAG}..."
        if ! docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" "$PROJECT_ROOT" >/dev/null 2>&1; then
            echo "Failed to build Docker image"
            return 1
        fi
    fi
    return 0
}

# Test container starts successfully
test_container_starts() {
    local container_id=$(docker run -d \
        --name "$TEST_CONTAINER_NAME" \
        -e CURRENT_NAMESPACE=test \
        "${IMAGE_NAME}:${IMAGE_TAG}" 2>&1)

    if [ $? -ne 0 ]; then
        echo "Failed to start container: $container_id"
        return 1
    fi

    # Wait for container to be running
    sleep 2

    local status=$(docker inspect -f '{{.State.Status}}' "$TEST_CONTAINER_NAME" 2>/dev/null)
    assert_equals "running" "$status" "Container should be running"

    # Cleanup
    docker rm -f "$TEST_CONTAINER_NAME" >/dev/null 2>&1
}

# Test container runs as non-root
test_container_non_root() {
    local container_id=$(docker run -d \
        --name "$TEST_CONTAINER_NAME" \
        -e CURRENT_NAMESPACE=test \
        "${IMAGE_NAME}:${IMAGE_TAG}" 2>&1)

    if [ $? -ne 0 ]; then
        echo "Failed to start container"
        return 1
    fi

    sleep 2

    # Check user ID
    local user_id=$(docker exec "$TEST_CONTAINER_NAME" id -u 2>/dev/null)
    assert_equals "101" "$user_id" "Container should run as nginx user (UID 101)"

    # Check username
    local username=$(docker exec "$TEST_CONTAINER_NAME" whoami 2>/dev/null)
    assert_equals "nginx" "$username" "Container should run as nginx user"

    # Cleanup
    docker rm -f "$TEST_CONTAINER_NAME" >/dev/null 2>&1
}

# Test health endpoint
test_container_health_endpoint() {
    local container_id=$(docker run -d \
        --name "$TEST_CONTAINER_NAME" \
        -e CURRENT_NAMESPACE=test \
        -p 8080:80 \
        "${IMAGE_NAME}:${IMAGE_TAG}" 2>&1)

    if [ $? -ne 0 ]; then
        echo "Failed to start container"
        return 1
    fi

    # Wait for nginx to be ready
    sleep 3

    # Test health endpoint
    local response=$(curl -s -w "\n%{http_code}" http://localhost:8080/health 2>/dev/null)
    local http_code=$(echo "$response" | tail -1)
    local body=$(echo "$response" | head -n -1)

    assert_equals "200" "$http_code" "Health endpoint should return 200"
    assert_contains "$body" "healthy" "Health response should contain 'healthy'"

    # Cleanup
    docker rm -f "$TEST_CONTAINER_NAME" >/dev/null 2>&1
}

# Test environment variable substitution
test_environment_substitution() {
    local container_id=$(docker run -d \
        --name "$TEST_CONTAINER_NAME" \
        -e CURRENT_NAMESPACE=test-namespace \
        -e PROXY_CONNECT_TIMEOUT=45 \
        -e PROXY_BUFFER_SIZE=8k \
        "${IMAGE_NAME}:${IMAGE_TAG}" 2>&1)

    if [ $? -ne 0 ]; then
        echo "Failed to start container"
        return 1
    fi

    sleep 2

    # Check that environment variables are set
    local namespace=$(docker exec "$TEST_CONTAINER_NAME" printenv CURRENT_NAMESPACE 2>/dev/null)
    assert_equals "test-namespace" "$namespace" "CURRENT_NAMESPACE should be set"

    # Check nginx config has substituted values
    local config=$(docker exec "$TEST_CONTAINER_NAME" cat /etc/nginx/includes/proxy.conf 2>/dev/null)
    assert_contains "$config" "45" "Config should have substituted timeout"
    assert_contains "$config" "8k" "Config should have substituted buffer size"

    # Cleanup
    docker rm -f "$TEST_CONTAINER_NAME" >/dev/null 2>&1
}

# Test nginx configuration validity
test_nginx_config_validity() {
    local container_id=$(docker run -d \
        --name "$TEST_CONTAINER_NAME" \
        -e CURRENT_NAMESPACE=test \
        "${IMAGE_NAME}:${IMAGE_TAG}" 2>&1)

    if [ $? -ne 0 ]; then
        echo "Failed to start container"
        return 1
    fi

    sleep 2

    # Test nginx configuration
    local result=$(docker exec "$TEST_CONTAINER_NAME" nginx -t 2>&1)
    assert_contains "$result" "syntax is ok" "Nginx config syntax should be valid"
    assert_contains "$result" "test is successful" "Nginx config test should succeed"

    # Cleanup
    docker rm -f "$TEST_CONTAINER_NAME" >/dev/null 2>&1
}

# Test container with custom routes
test_custom_routes() {
    # Create temporary routes file
    local temp_routes="$TEST_TEMP_DIR/custom-routes.conf"
    cat > "$temp_routes" << 'EOF'
location /test/ {
    proxy_pass http://test-service.namespace.svc.cluster.local:8080/;
    include /etc/nginx/includes/proxy.conf;
}
EOF

    local container_id=$(docker run -d \
        --name "$TEST_CONTAINER_NAME" \
        -e CURRENT_NAMESPACE=test \
        -v "$temp_routes:/etc/nginx/conf.d/routes.conf:ro" \
        "${IMAGE_NAME}:${IMAGE_TAG}" 2>&1)

    if [ $? -ne 0 ]; then
        echo "Failed to start container"
        return 1
    fi

    sleep 2

    # Check that custom routes are loaded
    local config=$(docker exec "$TEST_CONTAINER_NAME" cat /etc/nginx/conf.d/routes.conf 2>/dev/null)
    assert_contains "$config" "/test/" "Custom routes should be loaded"
    assert_contains "$config" "test-service" "Custom routes should have test service"

    # Cleanup
    docker rm -f "$TEST_CONTAINER_NAME" >/dev/null 2>&1
}

# Test container resource limits
test_container_resources() {
    # Start container with resource limits
    local container_id=$(docker run -d \
        --name "$TEST_CONTAINER_NAME" \
        -e CURRENT_NAMESPACE=test \
        --memory="256m" \
        --cpus="0.5" \
        "${IMAGE_NAME}:${IMAGE_TAG}" 2>&1)

    if [ $? -ne 0 ]; then
        echo "Failed to start container with resource limits"
        return 1
    fi

    sleep 2

    # Check container is still running with limits
    local status=$(docker inspect -f '{{.State.Status}}' "$TEST_CONTAINER_NAME" 2>/dev/null)
    assert_equals "running" "$status" "Container should run with resource limits"

    # Cleanup
    docker rm -f "$TEST_CONTAINER_NAME" >/dev/null 2>&1
}

# Test container signal handling
test_signal_handling() {
    local container_id=$(docker run -d \
        --name "$TEST_CONTAINER_NAME" \
        -e CURRENT_NAMESPACE=test \
        "${IMAGE_NAME}:${IMAGE_TAG}" 2>&1)

    if [ $? -ne 0 ]; then
        echo "Failed to start container"
        return 1
    fi

    sleep 2

    # Send SIGHUP to reload nginx
    docker exec "$TEST_CONTAINER_NAME" kill -HUP 1 2>/dev/null

    # Give nginx time to reload
    sleep 1

    # Check container is still running
    local status=$(docker inspect -f '{{.State.Status}}' "$TEST_CONTAINER_NAME" 2>/dev/null)
    assert_equals "running" "$status" "Container should still be running after reload"

    # Cleanup
    docker rm -f "$TEST_CONTAINER_NAME" >/dev/null 2>&1
}

# Cleanup function
cleanup_test_containers() {
    docker rm -f "$TEST_CONTAINER_NAME" >/dev/null 2>&1 || true
}

# Main test execution
main() {
    start_test_suite "Docker Container Tests"

    # Check prerequisites
    if ! check_docker; then
        end_test_suite "Docker Container Tests"
        return 0
    fi

    if ! build_test_image; then
        echo "Failed to build test image"
        end_test_suite "Docker Container Tests"
        return 1
    fi

    # Setup
    setup_test_environment
    trap cleanup_test_containers EXIT

    # Run tests
    run_test "Container starts successfully" test_container_starts
    run_test "Container runs as non-root" test_container_non_root
    run_test "Health endpoint accessible" test_container_health_endpoint
    run_test "Environment variable substitution" test_environment_substitution
    run_test "Nginx config validity" test_nginx_config_validity
    run_test "Custom routes loading" test_custom_routes
    run_test "Container resource limits" test_container_resources
    run_test "Signal handling" test_signal_handling

    # Cleanup
    teardown_test_environment

    end_test_suite "Docker Container Tests"
}

# Run tests if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi