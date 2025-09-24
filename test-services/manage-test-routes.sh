#!/bin/bash
# manage-test-routes.sh - Enable/disable test routes for NGINX Dev Gateway

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration
NAMESPACE="${NAMESPACE:-nathan}"
ACTION="${1:-enable}"

# Colors
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
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

# Enable test routes
enable_test_routes() {
    log_info "Enabling test routes in namespace $NAMESPACE..."

    # First, check if the main routes ConfigMap exists
    if ! kubectl get configmap nginx-gateway-routes -n "$NAMESPACE" >/dev/null 2>&1; then
        log_warn "Main routes ConfigMap doesn't exist, creating it..."
        kubectl create configmap nginx-gateway-routes \
            --from-literal="routes.conf=# Main routes configuration" \
            -n "$NAMESPACE"
    fi

    # Create test routes ConfigMap with namespace substitution
    sed "s/NAMESPACE_PLACEHOLDER/$NAMESPACE/g" "$SCRIPT_DIR/test-routes.yaml" | \
        kubectl apply -n "$NAMESPACE" -f -

    # Get current routes
    local current_routes=$(kubectl get configmap nginx-gateway-routes -n "$NAMESPACE" \
        -o jsonpath='{.data.routes\.conf}')

    # Check if test routes are already included
    if echo "$current_routes" | grep -q "/test/"; then
        log_warn "Test routes already present in configuration"
    else
        # Add include directive for test routes
        local updated_routes="${current_routes}

# Include test routes
include /etc/nginx/routes/test-routes.conf;"

        # Update the main routes ConfigMap
        kubectl create configmap nginx-gateway-routes-updated \
            --from-literal="routes.conf=$updated_routes" \
            -n "$NAMESPACE" \
            --dry-run=client -o yaml | \
            kubectl replace -f -
    fi

    # Update nginx deployment to mount test routes
    log_info "Updating nginx deployment to include test routes..."

    # Check if test routes volume is already mounted
    if kubectl get deployment nginx-gateway -n "$NAMESPACE" -o json | \
       grep -q "nginx-gateway-test-routes"; then
        log_info "Test routes already mounted in deployment"
    else
        # Patch deployment to add test routes volume
        kubectl patch deployment nginx-gateway -n "$NAMESPACE" --type='json' -p='[
            {
                "op": "add",
                "path": "/spec/template/spec/volumes/-",
                "value": {
                    "name": "test-routes",
                    "configMap": {
                        "name": "nginx-gateway-test-routes",
                        "items": [
                            {
                                "key": "test-routes.conf",
                                "path": "test-routes.conf"
                            }
                        ]
                    }
                }
            },
            {
                "op": "add",
                "path": "/spec/template/spec/containers/0/volumeMounts/-",
                "value": {
                    "name": "test-routes",
                    "mountPath": "/etc/nginx/routes/test-routes.conf",
                    "subPath": "test-routes.conf",
                    "readOnly": true
                }
            }
        ]' 2>/dev/null || log_warn "Test routes volume may already be configured"
    fi

    # Restart nginx pods to pick up changes
    kubectl rollout restart deployment/nginx-gateway -n "$NAMESPACE"

    log_info "Waiting for rollout to complete..."
    kubectl rollout status deployment/nginx-gateway -n "$NAMESPACE" --timeout=60s

    log_info "Test routes enabled successfully!"
    echo
    echo "Test endpoints available at:"
    echo "  - http://gateway/test/echo/"
    echo "  - ws://gateway/test/ws"
    echo "  - http://gateway/test/api/"
    echo "  - http://gateway/test/slow/"
    echo "  - http://gateway/test/health"
}

# Disable test routes
disable_test_routes() {
    log_info "Disabling test routes in namespace $NAMESPACE..."

    # Delete test routes ConfigMap
    kubectl delete configmap nginx-gateway-test-routes -n "$NAMESPACE" \
        --ignore-not-found=true

    # Remove test routes from main configuration
    local current_routes=$(kubectl get configmap nginx-gateway-routes -n "$NAMESPACE" \
        -o jsonpath='{.data.routes\.conf}' 2>/dev/null || echo "")

    # Remove test routes include
    local updated_routes=$(echo "$current_routes" | \
        grep -v "Include test routes" | \
        grep -v "include /etc/nginx/routes/test-routes.conf")

    # Update the main routes ConfigMap
    if [ -n "$updated_routes" ]; then
        kubectl create configmap nginx-gateway-routes \
            --from-literal="routes.conf=$updated_routes" \
            -n "$NAMESPACE" \
            --dry-run=client -o yaml | \
            kubectl replace -f -
    fi

    # Remove test routes volume from deployment
    kubectl patch deployment nginx-gateway -n "$NAMESPACE" --type='json' -p='[
        {
            "op": "remove",
            "path": "/spec/template/spec/volumes/2"
        },
        {
            "op": "remove",
            "path": "/spec/template/spec/containers/0/volumeMounts/2"
        }
    ]' 2>/dev/null || log_warn "Test routes volume may already be removed"

    # Restart nginx pods
    kubectl rollout restart deployment/nginx-gateway -n "$NAMESPACE"

    log_info "Waiting for rollout to complete..."
    kubectl rollout status deployment/nginx-gateway -n "$NAMESPACE" --timeout=60s

    log_info "Test routes disabled successfully!"
}

# Check test routes status
check_test_routes() {
    log_info "Checking test routes status in namespace $NAMESPACE..."

    # Check if test routes ConfigMap exists
    if kubectl get configmap nginx-gateway-test-routes -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "✓ Test routes ConfigMap exists"
    else
        echo "✗ Test routes ConfigMap not found"
    fi

    # Check if test routes are mounted
    if kubectl get deployment nginx-gateway -n "$NAMESPACE" -o json | \
       grep -q "nginx-gateway-test-routes"; then
        echo "✓ Test routes mounted in deployment"
    else
        echo "✗ Test routes not mounted in deployment"
    fi

    # Test the routes
    log_info "Testing route accessibility..."

    # Get a pod to test from
    local pod=$(kubectl get pods -n "$NAMESPACE" -l app=nginx-gateway \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -n "$pod" ]; then
        # Test if routes are configured
        if kubectl exec -n "$NAMESPACE" "$pod" -- \
           grep -q "/test/" /etc/nginx/conf.d/default.conf 2>/dev/null || \
           kubectl exec -n "$NAMESPACE" "$pod" -- \
           test -f /etc/nginx/routes/test-routes.conf 2>/dev/null; then
            echo "✓ Test routes configured in nginx"

            # Test actual route
            if kubectl exec -n "$NAMESPACE" "$pod" -- \
               curl -s http://localhost/test/health | grep -q "test_routes"; then
                echo "✓ Test routes are working"
            else
                echo "✗ Test routes not responding"
            fi
        else
            echo "✗ Test routes not configured in nginx"
        fi
    else
        echo "✗ No nginx-gateway pod found"
    fi
}

# Main execution
main() {
    # Show header
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   Test Routes Management               ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo
    echo "Namespace: $NAMESPACE"
    echo "Action: $ACTION"
    echo

    # Check prerequisites
    if ! command -v kubectl >/dev/null 2>&1; then
        log_error "kubectl is required but not installed"
        exit 1
    fi

    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi

    # Execute action
    case "$ACTION" in
        enable|on)
            enable_test_routes
            ;;
        disable|off)
            disable_test_routes
            ;;
        status|check)
            check_test_routes
            ;;
        help|--help|-h)
            cat << EOF
Usage: $0 [ACTION] [OPTIONS]

Manage test routes for NGINX Dev Gateway

ACTIONS:
    enable, on     Enable test routes
    disable, off   Disable test routes
    status, check  Check test routes status
    help          Show this help message

OPTIONS:
    NAMESPACE=namespace   Kubernetes namespace (default: nathan)

EXAMPLES:
    # Enable test routes
    $0 enable

    # Disable test routes
    $0 disable

    # Check status
    $0 status

    # Use different namespace
    NAMESPACE=dev $0 enable

EOF
            exit 0
            ;;
        *)
            log_error "Unknown action: $ACTION"
            echo "Valid actions: enable, disable, status, help"
            exit 1
            ;;
    esac
}

# Run main function
main