#!/bin/bash

# Test suite for route helper commands
# Tests discover-routes, switch-service, and cross-namespace routing

set -e

# Source test framework
SCRIPT_DIR="$(dirname "$0")"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test-framework.sh"

# Test namespaces
TEST_DEV_NS="test-dev-ns"
TEST_STABLE_NS="test-stable-ns"

# Cleanup function
cleanup_test_namespaces() {
    log_info "Cleaning up test namespaces..."
    kubectl delete namespace "$TEST_DEV_NS" --ignore-not-found=true 2>/dev/null || true
    kubectl delete namespace "$TEST_STABLE_NS" --ignore-not-found=true 2>/dev/null || true
    rm -f test-discovered-routes.conf test-switch-routes.conf test-template.conf 2>/dev/null || true
}

# Setup test namespaces
setup_test_namespaces() {
    log_info "Setting up test namespaces..."

    # Create namespaces
    kubectl create namespace "$TEST_DEV_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl create namespace "$TEST_STABLE_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    # Wait for namespaces to be ready
    kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/"$TEST_DEV_NS" --timeout=30s >/dev/null
    kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/"$TEST_STABLE_NS" --timeout=30s >/dev/null
}

# Deploy a simple test service to a namespace
deploy_test_service() {
    local namespace="$1"
    local service_name="$2"
    local port="${3:-8080}"

    log_info "Deploying $service_name to $namespace..."

    cat <<EOF | kubectl apply -n "$namespace" -f - >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: $service_name
spec:
  ports:
  - port: $port
    targetPort: $port
  selector:
    app: $service_name
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $service_name
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $service_name
  template:
    metadata:
      labels:
        app: $service_name
    spec:
      containers:
      - name: echo
        image: ealen/echo-server:latest
        ports:
        - containerPort: $port
        env:
        - name: PORT
          value: "$port"
        - name: NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
EOF

    # Wait for deployment to be ready
    kubectl rollout status deployment/"$service_name" -n "$namespace" --timeout=60s >/dev/null 2>&1 || true
}

# Test functions
test_generate_template() {
    export NAMESPACE="$TEST_DEV_NS"
    cd "$PROJECT_ROOT"
    ./manage.sh generate-routes test-template.conf >/dev/null 2>&1
    assert_file_exists "test-template.conf"
}

test_service_discovery() {
    # Deploy services to different namespaces
    deploy_test_service "$TEST_STABLE_NS" "user-service" 8080
    deploy_test_service "$TEST_STABLE_NS" "order-service" 8080
    deploy_test_service "$TEST_DEV_NS" "payment-service" 8080
    deploy_test_service "$TEST_DEV_NS" "nginx-gateway" 80

    # Run discovery
    export NAMESPACE="$TEST_DEV_NS"
    cd "$PROJECT_ROOT"
    ./manage.sh discover-routes test-discovered-routes.conf \
        --stable-namespace "$TEST_STABLE_NS" \
        --debug-services "payment-service" >/dev/null 2>&1

    # Verify the generated file
    assert_file_exists "test-discovered-routes.conf"

    # Check content
    local content=$(cat test-discovered-routes.conf)
    assert_contains "$content" "payment-service.\${CURRENT_NAMESPACE}"
    assert_contains "$content" "user-service.$TEST_STABLE_NS"
    assert_not_contains "$content" "nginx-gateway"
}

test_service_switching() {
    # Create initial routes file
    cat > test-switch-routes.conf <<EOF
# payment-service - STABLE VERSION
location /api/payment/ {
    set \$payment_upstream payment-service.$TEST_STABLE_NS.svc.cluster.local:8080;
    proxy_pass http://\$payment_upstream/;
    include /etc/nginx/includes/proxy.conf;
}
EOF

    # Create a ConfigMap to simulate existing routes
    kubectl create configmap nginx-gateway-routes \
        --from-file=example-routes.conf=test-switch-routes.conf \
        -n "$TEST_DEV_NS" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    # Test switching to debug
    export NAMESPACE="$TEST_DEV_NS"
    cd "$PROJECT_ROOT"
    ./manage.sh switch-service payment-service debug "$TEST_STABLE_NS" >/dev/null 2>&1

    # Get updated routes
    local updated_routes=$(kubectl get configmap nginx-gateway-routes -n "$TEST_DEV_NS" -o jsonpath='{.data.example-routes\.conf}')

    # Check if payment-service is now in debug mode
    assert_contains "$updated_routes" "payment-service.\${CURRENT_NAMESPACE}"

    # Test switching back to stable
    ./manage.sh switch-service payment-service stable "$TEST_STABLE_NS" >/dev/null 2>&1
    updated_routes=$(kubectl get configmap nginx-gateway-routes -n "$TEST_DEV_NS" -o jsonpath='{.data.example-routes\.conf}')
    assert_contains "$updated_routes" "payment-service.$TEST_STABLE_NS"

    # Clean up ConfigMap
    kubectl delete configmap nginx-gateway-routes -n "$TEST_DEV_NS" --ignore-not-found=true >/dev/null 2>&1
}

# Main test execution
main() {
    echo "====================================="
    echo "Route Helper Commands Test Suite"
    echo "====================================="
    echo

    # Clean up any previous test artifacts
    cleanup_test_namespaces

    # Setup test environment
    setup_test_namespaces

    # Run tests
    start_test_suite "Route Helper Commands"

    run_test "Generate Routes Template" test_generate_template
    run_test "Service Discovery" test_service_discovery
    run_test "Service Switching" test_service_switching

    end_test_suite

    # Cleanup
    cleanup_test_namespaces

    # Return appropriate exit code
    [ $TESTS_FAILED -eq 0 ] && exit 0 || exit 1
}

# Run tests if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi