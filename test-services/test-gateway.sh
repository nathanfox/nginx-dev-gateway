#!/bin/bash
# test-gateway.sh - Comprehensive testing of NGINX Dev Gateway with test services

set -e

# Configuration
GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"
NAMESPACE="${NAMESPACE:-nathan}"
VERBOSE="${VERBOSE:-0}"

# Colors
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Helper functions
log_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

# Run a test
run_test() {
    local test_name="$1"
    local test_function="$2"

    TESTS_RUN=$((TESTS_RUN + 1))
    log_test "$test_name"

    if $test_function; then
        log_pass "$test_name"
    else
        log_fail "$test_name"
    fi
}

# Test echo service
test_echo_service() {
    local response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d '{"message":"Hello from test"}' \
        "${GATEWAY_URL}/test/echo/" 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo "  Failed to connect to echo service"
        return 1
    fi

    if echo "$response" | grep -q "echo-service"; then
        [ "$VERBOSE" -eq 1 ] && echo "  Response: $response"
        return 0
    else
        echo "  Unexpected response: $response"
        return 1
    fi
}

# Test echo service delay
test_echo_delay() {
    local start=$(date +%s)
    local response=$(curl -s "${GATEWAY_URL}/test/echo/delay?ms=2000" 2>/dev/null)
    local end=$(date +%s)
    local duration=$((end - start))

    if [ $duration -ge 2 ]; then
        [ "$VERBOSE" -eq 1 ] && echo "  Delay worked: ${duration}s"
        return 0
    else
        echo "  Delay too short: ${duration}s (expected >= 2s)"
        return 1
    fi
}

# Test WebSocket connection
test_websocket() {
    # Using curl to test WebSocket upgrade headers
    local response=$(curl -s -i \
        -H "Connection: Upgrade" \
        -H "Upgrade: websocket" \
        -H "Sec-WebSocket-Version: 13" \
        -H "Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==" \
        "${GATEWAY_URL}/test/ws" 2>/dev/null | head -1)

    if echo "$response" | grep -q "101"; then
        [ "$VERBOSE" -eq 1 ] && echo "  WebSocket upgrade successful"
        return 0
    else
        echo "  WebSocket upgrade failed: $response"
        return 1
    fi
}

# Test Mock API - List users
test_mock_api_list() {
    local response=$(curl -s "${GATEWAY_URL}/test/api/users" 2>/dev/null)

    if echo "$response" | grep -q "Alice"; then
        [ "$VERBOSE" -eq 1 ] && echo "  Users list retrieved"
        return 0
    else
        echo "  Failed to get users list"
        return 1
    fi
}

# Test Mock API - Create user
test_mock_api_create() {
    local response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d '{"name":"Test User","email":"test@example.com"}' \
        "${GATEWAY_URL}/test/api/users" 2>/dev/null)

    if echo "$response" | grep -q "Test User"; then
        [ "$VERBOSE" -eq 1 ] && echo "  User created successfully"
        return 0
    else
        echo "  Failed to create user"
        return 1
    fi
}

# Test Mock API - Get specific user
test_mock_api_get_user() {
    local response=$(curl -s "${GATEWAY_URL}/test/api/users/1" 2>/dev/null)

    if echo "$response" | grep -q "Alice"; then
        [ "$VERBOSE" -eq 1 ] && echo "  User retrieved successfully"
        return 0
    else
        echo "  Failed to get user"
        return 1
    fi
}

# Test Mock API - Status endpoint
test_mock_api_status() {
    local response=$(curl -s "${GATEWAY_URL}/test/api/status" 2>/dev/null)

    if echo "$response" | grep -q "healthy"; then
        [ "$VERBOSE" -eq 1 ] && echo "  API status is healthy"
        return 0
    else
        echo "  API status check failed"
        return 1
    fi
}

# Test slow service
test_slow_service() {
    local response=$(curl -s --max-time 10 "${GATEWAY_URL}/test/slow/slow?delay=1000" 2>/dev/null)

    if echo "$response" | grep -q "delayed"; then
        [ "$VERBOSE" -eq 1 ] && echo "  Slow service responded"
        return 0
    else
        echo "  Slow service failed"
        return 1
    fi
}

# Test slow service timeout
test_slow_timeout() {
    local response=$(curl -s --max-time 5 "${GATEWAY_URL}/test/slow/slow?delay=10000" 2>/dev/null)
    local exit_code=$?

    if [ $exit_code -eq 28 ]; then
        [ "$VERBOSE" -eq 1 ] && echo "  Request timed out as expected"
        return 0
    else
        echo "  Request did not timeout (exit code: $exit_code)"
        return 1
    fi
}

# Test streaming response
test_slow_stream() {
    local response=$(curl -s --max-time 15 "${GATEWAY_URL}/test/slow/stream?chunks=3&chunkDelay=500" 2>/dev/null)

    if echo "$response" | grep -q "Stream complete"; then
        [ "$VERBOSE" -eq 1 ] && echo "  Stream completed"
        return 0
    else
        echo "  Stream failed"
        return 1
    fi
}

# Test gateway health
test_gateway_health() {
    local response=$(curl -s -o /dev/null -w "%{http_code}" "${GATEWAY_URL}/health" 2>/dev/null)

    if [ "$response" = "200" ]; then
        [ "$VERBOSE" -eq 1 ] && echo "  Gateway health check passed"
        return 0
    else
        echo "  Gateway health check failed (HTTP $response)"
        return 1
    fi
}

# Test 404 handling
test_404_handling() {
    local response=$(curl -s -o /dev/null -w "%{http_code}" "${GATEWAY_URL}/nonexistent/path" 2>/dev/null)

    if [ "$response" = "404" ]; then
        [ "$VERBOSE" -eq 1 ] && echo "  404 handling works"
        return 0
    else
        echo "  Unexpected response code: $response"
        return 1
    fi
}

# Test CORS headers
test_cors_headers() {
    local headers=$(curl -s -I "${GATEWAY_URL}/test/api/users" 2>/dev/null)

    if echo "$headers" | grep -qi "access-control-allow-origin"; then
        [ "$VERBOSE" -eq 1 ] && echo "  CORS headers present"
        return 0
    else
        echo "  CORS headers missing"
        return 1
    fi
}

# Main execution
main() {
    # Show header
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   NGINX Dev Gateway Test Suite        ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo
    echo "Configuration:"
    echo "  Gateway URL: $GATEWAY_URL"
    echo "  Namespace:   $NAMESPACE"
    echo

    # Check if gateway is accessible
    log_info "Checking gateway connectivity..."
    if ! curl -s -o /dev/null --connect-timeout 5 "$GATEWAY_URL"; then
        log_fail "Cannot connect to gateway at $GATEWAY_URL"
        echo
        echo "Make sure to:"
        echo "  1. Deploy the test services: ./test-services/deploy-test-services.sh"
        echo "  2. Update gateway routes to include test services"
        echo "  3. Port-forward the gateway: kubectl port-forward svc/nginx-gateway 8080:80 -n $NAMESPACE"
        exit 1
    fi

    # Run tests
    echo -e "${BLUE}Running Tests...${NC}"
    echo

    # Gateway tests
    run_test "Gateway health check" test_gateway_health
    run_test "404 handling" test_404_handling

    # Echo service tests
    run_test "Echo service POST" test_echo_service
    run_test "Echo service delay" test_echo_delay

    # WebSocket tests
    run_test "WebSocket upgrade" test_websocket

    # Mock API tests
    run_test "Mock API list users" test_mock_api_list
    run_test "Mock API create user" test_mock_api_create
    run_test "Mock API get user" test_mock_api_get_user
    run_test "Mock API status" test_mock_api_status
    run_test "Mock API CORS headers" test_cors_headers

    # Slow service tests
    run_test "Slow service response" test_slow_service
    run_test "Slow service timeout" test_slow_timeout
    run_test "Slow service streaming" test_slow_stream

    # Show summary
    echo
    echo -e "${BLUE}════════════════════════════════════════${NC}"
    echo -e "${BLUE}Test Summary${NC}"
    echo -e "${BLUE}════════════════════════════════════════${NC}"
    echo "Total tests: $TESTS_RUN"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"

    if [ $TESTS_FAILED -eq 0 ]; then
        echo
        echo -e "${GREEN}✓ All tests passed!${NC}"
        exit 0
    else
        echo
        echo -e "${RED}✗ Some tests failed${NC}"
        exit 1
    fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -g|--gateway)
            GATEWAY_URL="$2"
            shift 2
            ;;
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -h|--help)
            cat << EOF
Usage: $0 [OPTIONS]

Test NGINX Dev Gateway with test services

OPTIONS:
    -g, --gateway URL      Gateway URL (default: http://localhost:8080)
    -n, --namespace NS     Kubernetes namespace (default: nathan)
    -v, --verbose         Show verbose output
    -h, --help           Show this help message

EXAMPLES:
    # Test with default settings
    $0

    # Test with custom gateway URL
    $0 -g http://gateway.example.com

    # Test with verbose output
    $0 -v

EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run '$0 --help' for usage"
            exit 1
            ;;
    esac
done

# Run main function
main