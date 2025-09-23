#!/bin/bash
# test-e2e-deployment.sh - End-to-end deployment tests

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source test framework
source "$SCRIPT_DIR/../test-framework.sh"

# Source libraries
source "$PROJECT_ROOT/scripts/lib/common.sh"

# Test variables
E2E_NAMESPACE="${E2E_NAMESPACE:-e2e-test-$(date +%s)}"
CLEANUP_NAMESPACE="${CLEANUP_NAMESPACE:-1}"
REGISTRY="${REGISTRY:-}"
IMAGE_NAME="${IMAGE_NAME:-nginx-dev-gateway}"
IMAGE_TAG="${IMAGE_TAG:-e2e-test-$(date +%s)}"
FULL_IMAGE="${REGISTRY:+$REGISTRY/}${IMAGE_NAME}:${IMAGE_TAG}"

# Check prerequisites
check_prerequisites() {
    # Check kubectl
    if ! command -v kubectl >/dev/null 2>&1; then
        skip_test "E2E deployment tests" "kubectl not available"
        return 1
    fi

    # Check cluster connectivity
    if ! kubectl cluster-info >/dev/null 2>&1; then
        skip_test "E2E deployment tests" "Cannot connect to Kubernetes cluster"
        return 1
    fi

    # Check docker
    if ! command -v docker >/dev/null 2>&1; then
        skip_test "E2E deployment tests" "Docker not available"
        return 1
    fi

    # Check registry is configured
    if [ -z "$REGISTRY" ]; then
        echo "Warning: No REGISTRY configured, using local image"
    fi

    return 0
}

# Build and push image
build_and_push_image() {
    echo "Building Docker image: $FULL_IMAGE"

    # Build the image
    if ! docker build -t "$FULL_IMAGE" "$PROJECT_ROOT"; then
        echo "Failed to build Docker image"
        return 1
    fi

    # Push to registry if configured
    if [ -n "$REGISTRY" ]; then
        echo "Pushing image to registry: $REGISTRY"

        # Login to registry if it's ACR
        if [[ "$REGISTRY" == *"azurecr.io" ]]; then
            echo "Logging into Azure Container Registry..."
            az acr login --name "${REGISTRY%%.*}" 2>/dev/null || echo "Warning: ACR login failed, assuming already authenticated"
        fi

        # Push the image
        if ! docker push "$FULL_IMAGE"; then
            echo "Failed to push image to registry"
            return 1
        fi

        echo "Image pushed successfully: $FULL_IMAGE"
    else
        echo "No registry configured, using local image"
    fi

    return 0
}

# Create test namespace
setup_test_namespace() {
    echo "Creating test namespace: $E2E_NAMESPACE"
    kubectl create namespace "$E2E_NAMESPACE" 2>/dev/null || true
}

# Deploy gateway
test_deploy_gateway() {
    echo "Deploying gateway to namespace $E2E_NAMESPACE"
    echo "Using image: $FULL_IMAGE"

    # Apply ConfigMap
    kubectl apply -f "$PROJECT_ROOT/k8s/base/configmap.yaml" -n "$E2E_NAMESPACE"
    assert_exit_code 0 $? "ConfigMap should deploy successfully"

    # Create deployment with custom image
    cat "$PROJECT_ROOT/k8s/base/deployment.yaml" | \
        sed "s|nginx-dev-gateway:latest|$FULL_IMAGE|g" | \
        kubectl apply -n "$E2E_NAMESPACE" -f -
    assert_exit_code 0 $? "Deployment should deploy successfully"

    # Apply Service
    kubectl apply -f "$PROJECT_ROOT/k8s/base/service.yaml" -n "$E2E_NAMESPACE"
    assert_exit_code 0 $? "Service should deploy successfully"
}

# Wait for deployment
test_deployment_ready() {
    echo "Waiting for deployment to be ready..."

    local max_attempts=30
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        local ready=$(kubectl get deployment nginx-gateway -n "$E2E_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
        local desired=$(kubectl get deployment nginx-gateway -n "$E2E_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null)

        if [ "$ready" = "$desired" ] && [ -n "$ready" ]; then
            echo "Deployment is ready (${ready}/${desired} replicas)"
            return 0
        fi

        attempt=$((attempt + 1))
        sleep 2
    done

    echo "Deployment did not become ready in time"
    return 1
}

# Test pod status
test_pod_status() {
    local pods=$(kubectl get pods -n "$E2E_NAMESPACE" -l app=nginx-gateway -o jsonpath='{.items[*].status.phase}')

    for pod_phase in $pods; do
        assert_equals "Running" "$pod_phase" "All pods should be running"
    done
}

# Test service endpoints
test_service_endpoints() {
    local endpoints=$(kubectl get endpoints nginx-gateway -n "$E2E_NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}')

    if [ -z "$endpoints" ]; then
        echo "No service endpoints found"
        return 1
    fi

    echo "Service has endpoints: $endpoints"
    return 0
}

# Test config update
test_config_update() {
    # Update ConfigMap
    cat << EOF | kubectl apply -n "$E2E_NAMESPACE" -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-routes
data:
  routes.conf: |
    # Updated routes for testing
    location /e2e-test/ {
        proxy_pass http://test-service.${E2E_NAMESPACE}.svc.cluster.local:8080/;
        include /etc/nginx/includes/proxy.conf;
    }
EOF

    # Trigger rolling update
    kubectl rollout restart deployment/nginx-gateway -n "$E2E_NAMESPACE"

    # Wait for rollout
    kubectl rollout status deployment/nginx-gateway -n "$E2E_NAMESPACE" --timeout=60s
    assert_exit_code 0 $? "Rolling update should complete successfully"
}

# Test scaling
test_scaling() {
    # Scale up
    kubectl scale deployment/nginx-gateway -n "$E2E_NAMESPACE" --replicas=3

    # Wait for scale
    sleep 5

    local ready=$(kubectl get deployment nginx-gateway -n "$E2E_NAMESPACE" -o jsonpath='{.status.readyReplicas}')
    assert_equals "3" "$ready" "Should scale to 3 replicas"

    # Scale down
    kubectl scale deployment/nginx-gateway -n "$E2E_NAMESPACE" --replicas=1

    # Wait for scale
    sleep 5

    ready=$(kubectl get deployment nginx-gateway -n "$E2E_NAMESPACE" -o jsonpath='{.status.readyReplicas}')
    assert_equals "1" "$ready" "Should scale to 1 replica"
}

# Test pod logs
test_pod_logs() {
    local pod=$(kubectl get pods -n "$E2E_NAMESPACE" -l app=nginx-gateway -o jsonpath='{.items[0].metadata.name}')

    if [ -z "$pod" ]; then
        echo "No pod found"
        return 1
    fi

    local logs=$(kubectl logs "$pod" -n "$E2E_NAMESPACE" --tail=10 2>/dev/null)

    # Check for successful startup
    assert_not_contains "$logs" "error" "Logs should not contain errors"
    assert_not_contains "$logs" "failed" "Logs should not contain failures"
}

# Test resource limits
test_resource_limits() {
    local pod=$(kubectl get pods -n "$E2E_NAMESPACE" -l app=nginx-gateway -o jsonpath='{.items[0].metadata.name}')

    # Get container resource limits
    local memory_limit=$(kubectl get pod "$pod" -n "$E2E_NAMESPACE" -o jsonpath='{.spec.containers[0].resources.limits.memory}')
    local cpu_limit=$(kubectl get pod "$pod" -n "$E2E_NAMESPACE" -o jsonpath='{.spec.containers[0].resources.limits.cpu}')

    assert_equals "256Mi" "$memory_limit" "Memory limit should be set"
    assert_equals "500m" "$cpu_limit" "CPU limit should be set"
}

# Test security context
test_security_context() {
    local pod=$(kubectl get pods -n "$E2E_NAMESPACE" -l app=nginx-gateway -o jsonpath='{.items[0].metadata.name}')

    # Check security context
    local run_as_user=$(kubectl get pod "$pod" -n "$E2E_NAMESPACE" -o jsonpath='{.spec.securityContext.runAsUser}')
    local run_as_non_root=$(kubectl get pod "$pod" -n "$E2E_NAMESPACE" -o jsonpath='{.spec.securityContext.runAsNonRoot}')

    assert_equals "101" "$run_as_user" "Should run as nginx user (UID 101)"
    assert_equals "true" "$run_as_non_root" "Should run as non-root"
}

# Cleanup
cleanup_test_namespace() {
    if [ "$CLEANUP_NAMESPACE" -eq 1 ]; then
        echo "Cleaning up test namespace: $E2E_NAMESPACE"
        kubectl delete namespace "$E2E_NAMESPACE" --ignore-not-found=true 2>/dev/null || true

        # Optionally delete test image from registry
        if [ -n "$REGISTRY" ] && [ "${DELETE_TEST_IMAGE:-0}" -eq 1 ]; then
            echo "Deleting test image from registry: $FULL_IMAGE"
            if [[ "$REGISTRY" == *"azurecr.io" ]]; then
                az acr repository delete --name "${REGISTRY%%.*}" --image "${IMAGE_NAME}:${IMAGE_TAG}" --yes 2>/dev/null || true
            fi
        fi
    fi
}

# Main test execution
main() {
    start_test_suite "End-to-End Deployment Tests"

    # Check prerequisites
    if ! check_prerequisites; then
        end_test_suite "End-to-End Deployment Tests"
        return 0
    fi

    # Setup
    setup_test_namespace
    trap cleanup_test_namespace EXIT

    # Build and push image
    echo "Building and pushing test image..."
    if ! build_and_push_image; then
        echo "Failed to build/push image"
        end_test_suite "End-to-End Deployment Tests"
        return 1
    fi

    # Run tests
    run_test "Deploy gateway components" test_deploy_gateway
    run_test "Deployment becomes ready" test_deployment_ready
    run_test "Pod status is Running" test_pod_status
    run_test "Service has endpoints" test_service_endpoints
    run_test "ConfigMap update triggers rollout" test_config_update
    run_test "Deployment can scale" test_scaling
    run_test "Pod logs are clean" test_pod_logs
    run_test "Resource limits are set" test_resource_limits
    run_test "Security context is correct" test_security_context

    end_test_suite "End-to-End Deployment Tests"
}

# Run tests if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi