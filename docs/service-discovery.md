# Service Discovery Architecture for NGINX Dev Gateway

## Overview

This document describes how service discovery works in the namespace-aware NGINX API gateway for Kubernetes. The gateway leverages Kubernetes' built-in DNS-based service discovery while providing intelligent namespace routing and fallback mechanisms.

## Table of Contents

1. [Core Concepts](#core-concepts)
2. [Kubernetes DNS-Based Discovery](#kubernetes-dns-based-discovery)
3. [Namespace Resolution Strategy](#namespace-resolution-strategy)
4. [Implementation Details](#implementation-details)
5. [Configuration Examples](#configuration-examples)
6. [Advanced Features](#advanced-features)
7. [Troubleshooting Service Discovery](#troubleshooting-service-discovery)

## Core Concepts

### Service Naming Convention

In Kubernetes, every service is accessible via DNS using the following format:
- **Short name**: `service-name` (within same namespace)
- **Namespace-qualified**: `service-name.namespace`
- **Fully qualified**: `service-name.namespace.svc.cluster.local`

### Gateway Namespace Context

The gateway runs with awareness of its deployment namespace, enabling:
- Implicit routing to same-namespace services
- Explicit routing to cross-namespace services
- Intelligent fallback mechanisms

## Kubernetes DNS-Based Discovery

### How Kubernetes DNS Works

Kubernetes runs a DNS service (CoreDNS or kube-dns) that automatically creates DNS records for services:

```yaml
# When you create a service
apiVersion: v1
kind: Service
metadata:
  name: user-service
  namespace: developer-john
spec:
  ports:
    - port: 8080
  selector:
    app: user-api
```

This creates DNS records:
- `user-service.developer-john.svc.cluster.local` → Service ClusterIP
- `_http._tcp.user-service.developer-john.svc.cluster.local` → SRV record with port info

### NGINX DNS Resolution Configuration

```nginx
http {
    # Configure NGINX to use Kubernetes DNS
    resolver kube-dns.kube-system.svc.cluster.local valid=30s ipv6=off;
    resolver_timeout 10s;

    # DNS resolution happens when NGINX starts or when using variables
    location /api/users {
        # Static resolution (at startup)
        proxy_pass http://user-service.developer-john.svc.cluster.local:8080;
    }

    # Dynamic resolution (per request)
    location ~ ^/api/(?<service>[^/]+) {
        set $backend ${service}-service.${CURRENT_NAMESPACE}.svc.cluster.local;
        proxy_pass http://$backend:8080;
    }
}
```

## Namespace Resolution Strategy

### Resolution Hierarchy

The gateway implements a three-tier resolution strategy:

1. **Implicit Same-Namespace Resolution**
2. **Explicit Namespace Resolution**
3. **Fully Qualified Domain Names**

### 1. Implicit Same-Namespace Resolution

When only a service name is provided, the gateway assumes the same namespace:

```yaml
# ConfigMap in namespace: developer-john
routes:
  - prefix: /api/myapp
    backend: myapp-service  # Resolves to myapp-service.developer-john.svc.cluster.local
    port: 8080
```

**NGINX Template Processing**:
```bash
#!/bin/sh
# docker-entrypoint.sh

# Get current namespace from environment or mounted file
export CURRENT_NAMESPACE=${DEPLOY_NAMESPACE:-default}

# Process templates with namespace context
envsubst '$CURRENT_NAMESPACE' < /etc/nginx/routes.conf.template > /etc/nginx/routes.conf
```

### 2. Explicit Namespace Resolution

For cross-namespace communication, specify the target namespace:

```yaml
routes:
  - prefix: /api/billing
    backend:
      service: billing-service
      namespace: dev  # Explicit namespace
      port: 3000
    strip_prefix: true
```

**Generated NGINX Config**:
```nginx
location /api/billing {
    proxy_pass http://billing-service.dev.svc.cluster.local:3000/;
}
```

### 3. Fully Qualified Domain Names

For complete control, use the full DNS name:

```yaml
routes:
  - prefix: /api/external
    backend: external-service.production.svc.cluster.local:9000
```

## Implementation Details

### Dynamic Service Discovery

#### Template-Based Configuration

```nginx
# routes.conf.template
upstream backend_${SERVICE_NAME} {
    server ${SERVICE_NAME}.${SERVICE_NAMESPACE:-$CURRENT_NAMESPACE}.svc.cluster.local:${SERVICE_PORT};

    # Health checking
    keepalive 32;
    keepalive_timeout 60s;
}

location ${SERVICE_PREFIX} {
    proxy_pass http://backend_${SERVICE_NAME};

    # Include common proxy settings
    include /etc/nginx/includes/proxy.conf;
}
```

#### Environment Variable Injection

```bash
# Generate configuration from environment
export CURRENT_NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
export SERVICE_NAME="user-service"
export SERVICE_NAMESPACE="${TARGET_NAMESPACE:-$CURRENT_NAMESPACE}"
export SERVICE_PORT="8080"
export SERVICE_PREFIX="/api/users"

envsubst < routes.conf.template > routes.conf
```

### Service Availability Detection

#### Health-Based Routing

```nginx
upstream users_primary {
    server user-service.${CURRENT_NAMESPACE}.svc.cluster.local:8080 max_fails=3 fail_timeout=30s;
}

upstream users_fallback {
    server user-service.dev.svc.cluster.local:8080 backup;
}

location /api/users {
    proxy_pass http://users_primary;

    # Fallback handling
    proxy_next_upstream error timeout invalid_header http_502 http_503 http_504;
    proxy_next_upstream_tries 2;
}
```

#### Service Existence Validation

```bash
# validate-service.sh
#!/bin/bash

validate_service() {
    local service=$1
    local namespace=$2

    # Check DNS resolution
    nslookup ${service}.${namespace}.svc.cluster.local > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "✓ Service ${service} is resolvable in namespace ${namespace}"
        return 0
    else
        echo "✗ Service ${service} not found in namespace ${namespace}"
        return 1
    fi
}

# Validate all routes before applying configuration
for route in $(cat routes.yaml | yq '.routes[].backend'); do
    validate_service $route $CURRENT_NAMESPACE || exit 1
done
```

### Headless Service Discovery

For direct pod discovery (useful for stateful services):

```yaml
# Headless service definition
apiVersion: v1
kind: Service
metadata:
  name: database-pods
  namespace: developer-john
spec:
  clusterIP: None  # Headless service
  ports:
    - port: 5432
  selector:
    app: postgres
```

**NGINX Configuration for Headless Services**:
```nginx
upstream database {
    # CoreDNS returns all pod IPs for headless service
    server database-pods.developer-john.svc.cluster.local:5432 resolve;

    # Load balancing across pods
    least_conn;
    keepalive 16;
}

location /api/db {
    proxy_pass http://database;
}
```

## Configuration Examples

### Basic Service Discovery

```yaml
# configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-gateway-routes
  namespace: developer-john
data:
  routes.yaml: |
    routes:
      # Same namespace - simple name
      - prefix: /api/myfeature
        backend: myfeature-service
        port: 8080

      # Cross-namespace - explicit
      - prefix: /api/users
        backend:
          service: user-service
          namespace: dev
          port: 8080

      # Fully qualified
      - prefix: /api/legacy
        backend: legacy-app.production.svc.cluster.local:9000
```

### Advanced Discovery with Fallbacks

```yaml
routes:
  - prefix: /api/orders
    discovery:
      strategy: namespace-cascade
      primary:
        service: order-service
        namespace: ${CURRENT_NAMESPACE}
        port: 8080
      fallbacks:
        - service: order-service
          namespace: dev
          port: 8080
        - service: order-service
          namespace: staging
          port: 8080
```

### Dynamic Pattern-Based Discovery

```yaml
routes:
  # Route to service based on URL pattern
  - pattern: "^/svc/([a-z]+)/(.*)$"
    discovery:
      service_name: "$1-service"  # Capture group 1
      namespace: ${CURRENT_NAMESPACE}
      path: "$2"  # Capture group 2
      port: 8080
```

**Generated NGINX config**:
```nginx
location ~ ^/svc/([a-z]+)/(.*)$ {
    set $service $1;
    set $path $2;
    set $backend ${service}-service.${CURRENT_NAMESPACE}.svc.cluster.local;
    proxy_pass http://$backend:8080/$path;
}
```

## Advanced Features

### SRV Record Support

Kubernetes creates SRV records that include port information:

```nginx
# Use SRV records for automatic port discovery
location /api/dynamic {
    set $service_srv _http._tcp.myservice.${CURRENT_NAMESPACE}.svc.cluster.local;
    # NGINX Plus feature: resolve SRV records
    proxy_pass http://$service_srv;
}
```

### Service Mesh Integration

When using service mesh (Istio, Linkerd):

```yaml
# Deployment annotation
annotations:
  sidecar.istio.io/inject: "false"  # Gateway handles routing directly
```

The gateway can leverage service mesh for:
- Advanced traffic management
- Mutual TLS between services
- Distributed tracing

### DNS Caching Strategy

```nginx
http {
    # DNS caching configuration
    resolver kube-dns.kube-system.svc.cluster.local valid=30s;

    # Response caching for successful lookups
    proxy_cache_path /var/cache/nginx/dns levels=1:2 keys_zone=dns_cache:10m;

    location /api/ {
        proxy_cache dns_cache;
        proxy_cache_valid 200 302 5m;
        proxy_cache_valid 404 1m;
        proxy_cache_valid any 30s;

        # Cache key includes namespace
        proxy_cache_key "$scheme$request_method$host$request_uri$CURRENT_NAMESPACE";
    }
}
```

### Multi-Cluster Discovery (Future Enhancement)

```yaml
routes:
  - prefix: /api/global
    discovery:
      strategy: multi-cluster
      clusters:
        - name: primary
          service: global-service.namespace.svc.cluster.local
        - name: secondary
          service: global-service.namespace.svc.cluster-2.local
      load_balance: round-robin
```

## Troubleshooting Service Discovery

### Common Issues and Solutions

#### 1. Service Not Found (503 Bad Gateway)

**Symptoms**: NGINX returns 503 errors

**Check DNS Resolution**:
```bash
# From gateway pod
kubectl exec -n developer-john deployment/nginx-gateway -- \
  nslookup myservice.developer-john.svc.cluster.local

# Check if service exists
kubectl get svc myservice -n developer-john
```

**Solution**:
- Verify service name and namespace
- Check service selector matches pods
- Ensure service has endpoints

#### 2. Wrong Namespace Resolution

**Symptoms**: Requests going to wrong service

**Debug Commands**:
```bash
# Check current namespace
kubectl exec -n developer-john deployment/nginx-gateway -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/namespace

# Verify environment variables
kubectl exec -n developer-john deployment/nginx-gateway -- env | grep NAMESPACE
```

**Solution**:
- Verify CURRENT_NAMESPACE is set correctly
- Check ConfigMap namespace specifications
- Review route priorities

#### 3. DNS Resolution Timeout

**Symptoms**: Slow responses or timeouts

**Check DNS Performance**:
```bash
# Measure DNS resolution time
kubectl exec -n developer-john deployment/nginx-gateway -- \
  time nslookup myservice.developer-john.svc.cluster.local
```

**Solution**:
- Increase resolver timeout
- Add DNS caching
- Check CoreDNS performance

### Validation Scripts

#### Pre-deployment Validation

```bash
#!/bin/bash
# validate-routes.sh

NAMESPACE=${1:-developer-john}
ROUTES_FILE=${2:-routes.yaml}

echo "Validating routes for namespace: $NAMESPACE"

# Parse routes and validate each service
yq eval '.routes[]' $ROUTES_FILE | while read -r route; do
    service=$(echo $route | yq eval '.backend.service // .backend' -)
    namespace=$(echo $route | yq eval '.backend.namespace // env(NAMESPACE)' -)

    # Check if service exists
    if kubectl get svc $service -n $namespace &>/dev/null; then
        echo "✓ Service $service exists in namespace $namespace"

        # Check endpoints
        endpoints=$(kubectl get endpoints $service -n $namespace -o json | jq '.subsets | length')
        if [ "$endpoints" -gt "0" ]; then
            echo "  ✓ Service has active endpoints"
        else
            echo "  ⚠ Service has no active endpoints"
        fi
    else
        echo "✗ Service $service not found in namespace $namespace"
        exit 1
    fi
done
```

#### Runtime Health Check

```nginx
# Health check endpoint that validates service discovery
location /health/discovery {
    default_type application/json;

    content_by_lua_block {
        local services = {
            "user-service." .. os.getenv("CURRENT_NAMESPACE") .. ".svc.cluster.local",
            "billing-service.dev.svc.cluster.local"
        }

        local results = {}
        for _, service in ipairs(services) do
            local resolver = require "resty.dns.resolver"
            local r = resolver:new{nameservers = {"kube-dns.kube-system.svc.cluster.local"}}
            local answers = r:query(service)

            results[service] = answers and "resolved" or "failed"
        end

        ngx.say(cjson.encode(results))
    }
}
```

### Monitoring Service Discovery

#### Prometheus Metrics

```nginx
# Export metrics for service discovery
location /metrics/discovery {
    default_type text/plain;

    content_by_lua_block {
        -- Count of successful/failed DNS resolutions
        ngx.say("nginx_dns_resolution_success_total{namespace=\"" ..
                os.getenv("CURRENT_NAMESPACE") .. "\"} " .. dns_success_count)
        ngx.say("nginx_dns_resolution_failure_total{namespace=\"" ..
                os.getenv("CURRENT_NAMESPACE") .. "\"} " .. dns_failure_count)
    }
}
```

## Best Practices

1. **Always specify ports explicitly** - Don't rely on default ports
2. **Use health checks** - Verify service availability before routing
3. **Implement fallbacks** - Plan for service unavailability
4. **Cache DNS responses** - Reduce lookup overhead
5. **Monitor resolution metrics** - Track discovery performance
6. **Validate before deployment** - Check all services exist
7. **Use namespace prefixes** - Make cross-namespace routing explicit
8. **Document service dependencies** - Maintain a service map

## Summary

The NGINX Dev Gateway's service discovery leverages Kubernetes' native DNS while adding intelligent namespace-aware routing. This approach provides:

- **Simplicity**: Uses standard Kubernetes DNS
- **Flexibility**: Supports multiple resolution strategies
- **Reliability**: Includes fallback mechanisms
- **Performance**: DNS caching and health checks
- **Developer-friendly**: Implicit same-namespace routing

For more information, see the [main implementation plan](./api-gateway-plan.md).