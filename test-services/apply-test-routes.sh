#!/bin/bash
# apply-test-routes.sh - Simple script to add test routes to existing gateway

set -e

NAMESPACE="${NAMESPACE:-nathan}"
ACTION="${1:-apply}"

# Colors
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly NC='\033[0m'

apply_routes() {
    echo -e "${GREEN}Applying test routes to namespace $NAMESPACE...${NC}"

    # Create/update the routes ConfigMap with test routes
    cat << EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-gateway-routes
data:
  example-routes.conf: |
    # Test service routes for NGINX Dev Gateway

    # Echo service - HTTP echo testing
    location /test/echo/ {
        proxy_pass http://echo-service.$NAMESPACE.svc.cluster.local:8080/;
        include /etc/nginx/includes/proxy.conf;
    }

    # WebSocket service - WebSocket testing
    location /test/ws {
        proxy_pass http://websocket-service.$NAMESPACE.svc.cluster.local:8080/ws;
        include /etc/nginx/includes/websocket.conf;
    }

    # Mock API - REST API testing
    location /test/api/ {
        proxy_pass http://mock-api.$NAMESPACE.svc.cluster.local:8080/api/;
        include /etc/nginx/includes/proxy.conf;
    }

    # Slow service - Timeout and delay testing
    location /test/slow/ {
        proxy_pass http://slow-service.$NAMESPACE.svc.cluster.local:8080/;
        # Note: Using default proxy settings from proxy.conf
        # Timeouts are already configured there
        include /etc/nginx/includes/proxy.conf;
    }

    # Test health endpoint
    location /test/health {
        default_type application/json;
        return 200 '{"status":"ok","test_routes":"enabled"}\n';
    }
EOF

    # Restart nginx to pick up changes
    kubectl rollout restart deployment/nginx-gateway -n "$NAMESPACE"

    echo -e "${GREEN}Waiting for rollout...${NC}"
    kubectl rollout status deployment/nginx-gateway -n "$NAMESPACE" --timeout=60s

    echo -e "${GREEN}✓ Test routes applied!${NC}"
    echo
    echo "Test endpoints:"
    echo "  • http://localhost:8080/test/echo/"
    echo "  • ws://localhost:8080/test/ws"
    echo "  • http://localhost:8080/test/api/"
    echo "  • http://localhost:8080/test/slow/"
    echo "  • http://localhost:8080/test/health"
}

remove_routes() {
    echo -e "${YELLOW}Removing test routes from namespace $NAMESPACE...${NC}"

    # Restore empty routes
    kubectl create configmap nginx-gateway-routes \
        --from-literal="example-routes.conf=# No routes configured" \
        -n "$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -

    # Restart nginx
    kubectl rollout restart deployment/nginx-gateway -n "$NAMESPACE"
    kubectl rollout status deployment/nginx-gateway -n "$NAMESPACE" --timeout=60s

    echo -e "${GREEN}✓ Test routes removed!${NC}"
}

case "$ACTION" in
    apply|add)
        apply_routes
        ;;
    remove|delete)
        remove_routes
        ;;
    *)
        echo "Usage: $0 [apply|remove]"
        echo "  apply  - Add test routes to gateway"
        echo "  remove - Remove test routes from gateway"
        exit 1
        ;;
esac