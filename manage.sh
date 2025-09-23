#!/bin/bash

set -e

# Configuration
IMAGE_NAME="${IMAGE_NAME:-nginx-dev-gateway}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
REGISTRY="${REGISTRY:-}"
NAMESPACE="${NAMESPACE:-}"  # Can be set via environment variable
ROUTES_FILE=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Functions
print_usage() {
    cat << EOF
Usage: $0 <command> [options]

Commands:
    build                   Build the Docker image
    push                    Push image to registry
    deploy                  Deploy gateway to namespace
    update-routes [file]    Update route configuration
    test                    Run tests
    logs                    View gateway logs
    status                  Check deployment status
    reload                  Reload NGINX configuration
    uninstall               Remove gateway from namespace
    port-forward [port]     Port-forward to local machine

Options:
    -n, --namespace     Target namespace (or set NAMESPACE env var)
    -r, --registry      Docker registry URL (or set REGISTRY env var)
    -t, --tag          Docker image tag (or set IMAGE_TAG env var)
    -h, --help         Show this help message

Environment Variables:
    NAMESPACE          Default namespace for operations
    REGISTRY           Default Docker registry
    IMAGE_NAME         Docker image name (default: nginx-dev-gateway)
    IMAGE_TAG          Docker image tag (default: latest)

Examples:
    # Using environment variable
    export NAMESPACE=developer-john
    $0 deploy
    $0 logs

    # Using command line flag (overrides env var)
    $0 deploy -n developer-jane

    # Mixed usage
    export NAMESPACE=developer-john
    $0 status                        # uses developer-john
    $0 status -n developer-jane      # uses developer-jane

EOF
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

check_namespace() {
    if [ -z "$NAMESPACE" ]; then
        log_error "Namespace is required. Use -n <namespace> or set NAMESPACE environment variable"
        echo "Example: export NAMESPACE=developer-john"
        exit 1
    fi
    log_info "Using namespace: ${NAMESPACE}"
}

check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed or not in PATH"
        exit 1
    fi
}

check_docker() {
    if ! command -v docker &> /dev/null; then
        log_error "docker is not installed or not in PATH"
        exit 1
    fi
}

# Build Docker image
build_image() {
    log_info "Building Docker image: ${IMAGE_NAME}:${IMAGE_TAG}"
    check_docker

    docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" .

    if [ $? -eq 0 ]; then
        log_info "Image built successfully: ${IMAGE_NAME}:${IMAGE_TAG}"
    else
        log_error "Failed to build image"
        exit 1
    fi
}

# Push image to registry
push_image() {
    check_docker

    if [ -z "$REGISTRY" ]; then
        log_error "Registry not specified. Use -r <registry> or set REGISTRY environment variable"
        exit 1
    fi

    local full_image="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"

    log_info "Tagging image for registry: ${full_image}"
    docker tag "${IMAGE_NAME}:${IMAGE_TAG}" "${full_image}"

    log_info "Pushing image to registry: ${full_image}"
    docker push "${full_image}"

    if [ $? -eq 0 ]; then
        log_info "Image pushed successfully"
    else
        log_error "Failed to push image"
        exit 1
    fi
}

# Deploy to Kubernetes
deploy_gateway() {
    check_namespace
    check_kubectl

    log_info "Deploying NGINX gateway to namespace: ${NAMESPACE}"

    # Create namespace if it doesn't exist
    kubectl create namespace "${NAMESPACE}" 2>/dev/null || true

    # Apply configurations
    kubectl apply -f k8s/base/configmap.yaml -n "${NAMESPACE}"

    # Handle image registry if specified
    if [ -n "$REGISTRY" ]; then
        local full_image="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
        log_info "Using image from registry: ${full_image}"

        # Apply deployment and update image in one step using kubectl set image
        kubectl apply -f k8s/base/deployment.yaml -n "${NAMESPACE}"
        kubectl set image deployment/nginx-gateway nginx="${full_image}" -n "${NAMESPACE}"
    else
        log_warning "No REGISTRY specified. Using local image (may fail if cluster can't access it)"
        kubectl apply -f k8s/base/deployment.yaml -n "${NAMESPACE}"
    fi

    kubectl apply -f k8s/base/service.yaml -n "${NAMESPACE}"

    # Wait for deployment
    log_info "Waiting for deployment to be ready..."
    kubectl rollout status deployment/nginx-gateway -n "${NAMESPACE}" --timeout=60s

    if [ $? -eq 0 ]; then
        log_info "Gateway deployed successfully"
        log_info "To access the gateway, run:"
        echo "    $0 port-forward -n ${NAMESPACE} 8080"
    else
        log_error "Deployment failed"
        exit 1
    fi
}

# Update route configuration
update_routes() {
    check_namespace
    check_kubectl

    if [ -n "$1" ]; then
        ROUTES_FILE="$1"
        if [ ! -f "$ROUTES_FILE" ]; then
            log_error "Routes file not found: ${ROUTES_FILE}"
            exit 1
        fi

        log_info "Updating routes from file: ${ROUTES_FILE}"
        kubectl create configmap nginx-gateway-routes \
            --from-file="${ROUTES_FILE}" \
            --dry-run=client -o yaml | \
            kubectl apply -f - -n "${NAMESPACE}"
    else
        log_info "Opening ConfigMap for editing..."
        kubectl edit configmap nginx-gateway-routes -n "${NAMESPACE}"
    fi

    # Reload NGINX
    reload_nginx
}

# Reload NGINX configuration
reload_nginx() {
    check_namespace
    check_kubectl

    log_info "Reloading NGINX configuration in namespace: ${NAMESPACE}"

    # Get pod name
    POD=$(kubectl get pods -n "${NAMESPACE}" -l app=nginx-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$POD" ]; then
        log_error "No gateway pod found in namespace: ${NAMESPACE}"
        exit 1
    fi

    kubectl exec -n "${NAMESPACE}" "$POD" -- nginx -s reload

    if [ $? -eq 0 ]; then
        log_info "NGINX configuration reloaded successfully"
    else
        log_error "Failed to reload NGINX configuration"
        exit 1
    fi
}

# View logs
view_logs() {
    check_namespace
    check_kubectl

    log_info "Viewing logs for gateway in namespace: ${NAMESPACE}"
    kubectl logs -f deployment/nginx-gateway -n "${NAMESPACE}"
}

# Check status
check_status() {
    check_namespace
    check_kubectl

    log_info "Checking gateway status in namespace: ${NAMESPACE}"

    echo -e "\n${GREEN}Deployment:${NC}"
    kubectl get deployment nginx-gateway -n "${NAMESPACE}"

    echo -e "\n${GREEN}Pods:${NC}"
    kubectl get pods -l app=nginx-gateway -n "${NAMESPACE}"

    echo -e "\n${GREEN}Service:${NC}"
    kubectl get service nginx-gateway -n "${NAMESPACE}"

    echo -e "\n${GREEN}ConfigMap:${NC}"
    kubectl get configmap nginx-gateway-routes -n "${NAMESPACE}" 2>/dev/null || echo "No routes ConfigMap found"
}

# Port forward
port_forward() {
    check_namespace
    check_kubectl

    local port="${1:-8080}"

    log_info "Starting port-forward from localhost:${port} to gateway in namespace: ${NAMESPACE}"
    log_info "Access the gateway at: http://localhost:${port}"
    log_info "Press Ctrl+C to stop"

    kubectl port-forward -n "${NAMESPACE}" service/nginx-gateway "${port}:80"
}

# Uninstall gateway
uninstall_gateway() {
    check_namespace
    check_kubectl

    log_warning "Removing gateway from namespace: ${NAMESPACE}"

    kubectl delete -f k8s/base/service.yaml -n "${NAMESPACE}" 2>/dev/null || true
    kubectl delete -f k8s/base/deployment.yaml -n "${NAMESPACE}" 2>/dev/null || true
    kubectl delete -f k8s/base/configmap.yaml -n "${NAMESPACE}" 2>/dev/null || true

    log_info "Gateway removed from namespace: ${NAMESPACE}"
}

# Run tests
run_tests() {
    check_namespace
    check_kubectl

    log_info "Running tests in namespace: ${NAMESPACE}"

    # Check if gateway is deployed
    if ! kubectl get deployment nginx-gateway -n "${NAMESPACE}" &>/dev/null; then
        log_error "Gateway not deployed in namespace: ${NAMESPACE}"
        exit 1
    fi

    # Run basic connectivity test
    POD=$(kubectl get pods -n "${NAMESPACE}" -l app=nginx-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$POD" ]; then
        log_error "No gateway pod found"
        exit 1
    fi

    log_info "Testing health endpoint..."
    kubectl exec -n "${NAMESPACE}" "$POD" -- curl -s http://localhost/health

    if [ $? -eq 0 ]; then
        log_info "Health check passed"
    else
        log_error "Health check failed"
        exit 1
    fi
}

# Parse command line arguments
COMMAND=""
POSITIONAL=()

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
        -t|--tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        build|push|deploy|update-routes|test|logs|status|reload|uninstall|port-forward)
            COMMAND="$1"
            shift
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

# Execute command
case $COMMAND in
    build)
        build_image
        ;;
    push)
        push_image
        ;;
    deploy)
        deploy_gateway
        ;;
    update-routes)
        update_routes "${POSITIONAL[0]}"
        ;;
    test)
        run_tests
        ;;
    logs)
        view_logs
        ;;
    status)
        check_status
        ;;
    reload)
        reload_nginx
        ;;
    uninstall)
        uninstall_gateway
        ;;
    port-forward)
        port_forward "${POSITIONAL[0]}"
        ;;
    *)
        log_error "Unknown command: ${COMMAND}"
        print_usage
        exit 1
        ;;
esac