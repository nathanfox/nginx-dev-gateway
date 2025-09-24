#!/bin/bash
# deploy-test-services.sh - Build and deploy test services to Kubernetes

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration
NAMESPACE="${NAMESPACE:-nathan}"
REGISTRY="${REGISTRY:-}"
BUILD_ONLY="${BUILD_ONLY:-0}"
SERVICES="echo-service websocket-service mock-api slow-service"

# Colors
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Build service image
build_service() {
    local service="$1"
    local tag="${REGISTRY:+$REGISTRY/}$service:latest"

    log_info "Building $service..."

    if docker build -t "$tag" "$SCRIPT_DIR/$service"; then
        log_info "Successfully built $tag"

        # Push to registry if configured
        if [ -n "$REGISTRY" ] && [ "$BUILD_ONLY" -eq 0 ]; then
            log_info "Pushing $tag to registry..."
            if docker push "$tag"; then
                log_info "Successfully pushed $tag"
            else
                log_error "Failed to push $tag"
                return 1
            fi
        fi
    else
        log_error "Failed to build $service"
        return 1
    fi
}

# Deploy service to Kubernetes
deploy_service() {
    local service="$1"
    local manifest="$SCRIPT_DIR/$service/k8s/deployment.yaml"

    if [ ! -f "$manifest" ]; then
        log_error "Manifest not found: $manifest"
        return 1
    fi

    log_info "Deploying $service to namespace $NAMESPACE..."

    # Update image tag if registry is configured
    if [ -n "$REGISTRY" ]; then
        sed "s|image: $service:latest|image: $REGISTRY/$service:latest|g" "$manifest" | \
            kubectl apply -n "$NAMESPACE" -f -
    else
        kubectl apply -n "$NAMESPACE" -f "$manifest"
    fi

    if [ $? -eq 0 ]; then
        log_info "Successfully deployed $service"
    else
        log_error "Failed to deploy $service"
        return 1
    fi
}

# Wait for deployment to be ready
wait_for_deployment() {
    local service="$1"
    local max_wait=60
    local count=0

    log_info "Waiting for $service to be ready..."

    while [ $count -lt $max_wait ]; do
        local ready=$(kubectl get deployment "$service" -n "$NAMESPACE" \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
        local desired=$(kubectl get deployment "$service" -n "$NAMESPACE" \
            -o jsonpath='{.spec.replicas}' 2>/dev/null)

        if [ "$ready" = "$desired" ] && [ -n "$ready" ]; then
            log_info "$service is ready ($ready/$desired replicas)"
            return 0
        fi

        sleep 2
        count=$((count + 2))
    done

    log_warn "$service not ready after ${max_wait}s"
    return 1
}

# Create test routes ConfigMap
create_test_routes() {
    log_info "Creating test routes ConfigMap..."

    cat << EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: test-routes
data:
  test-routes.conf: |
    # Test service routes for NGINX Dev Gateway

    # Echo service
    location /test/echo/ {
        proxy_pass http://echo-service.$NAMESPACE.svc.cluster.local:8080/;
        include /etc/nginx/includes/proxy.conf;
    }

    # WebSocket service
    location /test/ws {
        proxy_pass http://websocket-service.$NAMESPACE.svc.cluster.local:8080/ws;
        include /etc/nginx/includes/websocket.conf;
    }

    # Mock API
    location /test/api/ {
        proxy_pass http://mock-api.$NAMESPACE.svc.cluster.local:8080/api/;
        include /etc/nginx/includes/proxy.conf;
    }

    # Slow service
    location /test/slow/ {
        proxy_pass http://slow-service.$NAMESPACE.svc.cluster.local:8080/;
        include /etc/nginx/includes/proxy.conf;

        # Increase timeout for slow service
        proxy_connect_timeout 120;
        proxy_send_timeout 120;
        proxy_read_timeout 120;
    }
EOF

    if [ $? -eq 0 ]; then
        log_info "Test routes ConfigMap created"
    else
        log_error "Failed to create test routes ConfigMap"
        return 1
    fi
}

# Show service URLs
show_service_urls() {
    echo
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "${GREEN}Test Services Deployed Successfully!${NC}"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo
    echo "Access test services through the gateway:"
    echo "  Echo Service:     http://gateway/test/echo/"
    echo "  WebSocket:        ws://gateway/test/ws"
    echo "  Mock API:         http://gateway/test/api/"
    echo "  Slow Service:     http://gateway/test/slow/"
    echo
    echo "Direct service endpoints (within cluster):"
    for service in $SERVICES; do
        echo "  $service: http://$service.$NAMESPACE.svc.cluster.local:8080"
    done
    echo
    echo "To test from outside the cluster:"
    echo "  kubectl port-forward svc/nginx-gateway 8080:80 -n $NAMESPACE"
    echo
}

# Main execution
main() {
    # Show header
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   Test Services Deployment Script     ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo
    echo "Configuration:"
    echo "  Namespace: $NAMESPACE"
    echo "  Registry:  ${REGISTRY:-<local>}"
    echo "  Services:  $SERVICES"
    echo

    # Check prerequisites
    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker is required but not installed"
        exit 1
    fi

    if [ "$BUILD_ONLY" -eq 0 ]; then
        if ! command -v kubectl >/dev/null 2>&1; then
            log_error "kubectl is required but not installed"
            exit 1
        fi

        if ! kubectl cluster-info >/dev/null 2>&1; then
            log_error "Cannot connect to Kubernetes cluster"
            exit 1
        fi

        # Create namespace if it doesn't exist
        kubectl create namespace "$NAMESPACE" 2>/dev/null || true
    fi

    # Build and deploy each service
    for service in $SERVICES; do
        echo
        if ! build_service "$service"; then
            log_error "Failed to build $service"
            exit 1
        fi

        if [ "$BUILD_ONLY" -eq 0 ]; then
            if ! deploy_service "$service"; then
                log_error "Failed to deploy $service"
                exit 1
            fi
        fi
    done

    # If not build-only, wait for deployments and create routes
    if [ "$BUILD_ONLY" -eq 0 ]; then
        echo
        log_info "Waiting for all deployments to be ready..."

        for service in $SERVICES; do
            wait_for_deployment "$service"
        done

        # Create test routes
        create_test_routes

        # Show success message and URLs
        show_service_urls
    else
        echo
        log_info "All services built successfully (build-only mode)"
    fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -r|--registry)
            REGISTRY="$2"
            shift 2
            ;;
        --build-only)
            BUILD_ONLY=1
            shift
            ;;
        -h|--help)
            cat << EOF
Usage: $0 [OPTIONS]

Deploy test services for NGINX Dev Gateway

OPTIONS:
    -n, --namespace NAMESPACE   Kubernetes namespace (default: nathan)
    -r, --registry REGISTRY     Container registry (optional)
    --build-only               Only build images, don't deploy
    -h, --help                 Show this help message

EXAMPLES:
    # Build and deploy locally
    $0

    # Deploy to specific namespace
    $0 -n test-namespace

    # Build and push to registry
    $0 -r myregistry.azurecr.io

    # Build only (no deployment)
    $0 --build-only

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