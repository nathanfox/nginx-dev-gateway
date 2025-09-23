# NGINX API Gateway for Kubernetes - Implementation Plan

## Project Overview
A lightweight, namespace-aware NGINX-based API gateway for Kubernetes that enables developers to debug and interact with microservices across namespaces. The gateway is deployed to a specific namespace and provides intelligent routing to services within the same namespace (for debugging local services) and to other namespaces (for accessing shared services in dev/staging environments).

## Problem Statement
Developers need a simple way to access multiple microservices running in a Kubernetes cluster through a single local port. The solution should:
- **Deploy to a specific namespace** (required parameter during deployment)
- **Prioritize same-namespace routing** for debugging services in the developer's workspace
- **Support cross-namespace routing** to access shared services in dev/staging namespaces
- Route requests based on URL path prefixes
- Support both HTTP and WebSocket protocols
- Be configurable via ConfigMaps or environment variables
- Work seamlessly with `kubectl port-forward`

## Architecture Design

### Core Components

#### 1. NGINX Docker Image
- **Base Image**: Alpine Linux for minimal footprint (~5MB base)
- **NGINX Version**: Latest stable release
- **Configuration**: Template-based with environment variable substitution
- **Features**:
  - HTTP/1.1 and HTTP/2 support
  - WebSocket protocol support
  - Health check endpoint
  - Request/response logging
  - Graceful reload capability

#### 2. Configuration Management
- **Primary**: Kubernetes ConfigMap for route definitions
- **Secondary**: Environment variables for runtime parameters
- **Volume Mounts**: `/etc/nginx/conf.d/` for dynamic configurations
- **Hot Reload**: Optional via config watcher sidecar

#### 3. Routing Strategy
- **Input URL Pattern**: `http://localhost:{port}/{service-prefix}/{path}`
- **Output Pattern**: `http://{service}.{namespace}.svc.cluster.local/{path}`
- **Namespace Resolution**:
  - Default: Routes to services in the **same namespace** as the gateway
  - Explicit: Routes to specified namespace when configured
  - Smart routing: Automatically detects if service exists in current namespace first
- **Features**:
  - Path prefix matching
  - Optional prefix stripping
  - WebSocket upgrade detection
  - Custom header injection
  - Cross-namespace routing with explicit configuration
  - Namespace-aware service discovery

## Detailed Project Structure

```
nginx-dev-gateway/
├── Dockerfile                          # Multi-stage build for NGINX image
├── .dockerignore                       # Exclude unnecessary files from build
├── .gitignore                          # Git ignore patterns
│
├── nginx/                              # NGINX configuration files
│   ├── nginx.conf.template            # Main NGINX configuration
│   ├── conf.d/
│   │   ├── default.conf.template      # Default server configuration
│   │   └── routes.conf.template        # Dynamic routing configuration
│   ├── includes/
│   │   ├── proxy.conf                 # Common proxy settings
│   │   ├── websocket.conf             # WebSocket upgrade configuration
│   │   └── security.conf              # Security headers
│   └── scripts/
│       └── docker-entrypoint.sh       # Container startup script
│
├── k8s/                                # Kubernetes manifests
│   ├── base/
│   │   ├── configmap.yaml            # Route configuration
│   │   ├── deployment.yaml           # Gateway deployment
│   │   ├── service.yaml              # ClusterIP service
│   │   └── serviceaccount.yaml       # RBAC if needed
│   ├── overlays/
│   │   ├── dev/                      # Development environment
│   │   └── prod/                     # Production environment
│   └── kustomization.yaml            # Kustomize configuration
│
├── scripts/                            # Management scripts
│   ├── manage.sh                      # Main management script
│   ├── lib/
│   │   ├── docker.sh                 # Docker operations
│   │   ├── k8s.sh                    # Kubernetes operations
│   │   └── config.sh                 # Configuration management
│   └── hooks/                        # Git hooks (optional)
│
├── tests/                              # Testing infrastructure
│   ├── unit/                          # Unit tests
│   │   └── nginx-config-test.sh      # NGINX config validation
│   ├── integration/                   # Integration tests
│   │   ├── routing-test.sh           # Route validation
│   │   └── websocket-test.sh         # WebSocket testing
│   ├── test-services/                 # Mock services for testing
│   │   ├── echo-service/
│   │   │   ├── Dockerfile
│   │   │   ├── app.js                # Simple echo server
│   │   │   └── k8s-manifest.yaml
│   │   ├── websocket-service/
│   │   │   ├── Dockerfile
│   │   │   ├── app.js                # WebSocket echo server
│   │   │   └── k8s-manifest.yaml
│   │   └── mock-api/
│   │       ├── Dockerfile
│   │       ├── app.py                # REST API mock
│   │       └── k8s-manifest.yaml
│   └── load/                          # Load testing
│       └── k6-script.js               # k6 load test scenarios
│
├── examples/                           # Usage examples
│   ├── sample-routes.yaml             # Example route configurations
│   ├── multi-namespace.yaml           # Cross-namespace routing
│   └── websocket-routes.yaml          # WebSocket configuration
│
├── docs/                               # Documentation
│   ├── api-gateway-plan.md           # This document
│   ├── configuration-guide.md        # Configuration reference
│   ├── deployment-guide.md           # Deployment instructions
│   └── troubleshooting.md            # Common issues and solutions
│
└── README.md                          # Project overview and quick start
```

## Implementation Phases

### Phase 1: Core NGINX Setup (Week 1)
1. **Create Base Docker Image**
   - Alpine Linux base with NGINX
   - Multi-stage build for optimization
   - Non-root user execution

2. **Develop NGINX Configuration Templates**
   - Main nginx.conf with worker settings
   - Proxy configuration includes
   - WebSocket upgrade handling
   - Error page templates

3. **Implement Dynamic Routing**
   - Path-based location blocks
   - Service discovery via DNS
   - Namespace resolution

### Phase 2: Configuration System (Week 1-2)
1. **ConfigMap Structure**
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: nginx-gateway-routes
   data:
     routes.yaml: |
       routes:
         - prefix: /api/users
           backend:
             service: user-service
             namespace: default
             port: 8080
           strip_prefix: false
           timeout: 30s
         - prefix: /api/orders
           backend:
             service: order-service
             namespace: production
             port: 3000
           strip_prefix: true
           timeout: 60s
         - prefix: /ws
           backend:
             service: websocket-service
             namespace: default
             port: 8080
           websocket: true
   ```

2. **Environment Variable Support**
   ```bash
   # REQUIRED: Deployment namespace
   DEPLOY_NAMESPACE=developer-john  # Required for deployment
   CURRENT_NAMESPACE=developer-john  # Injected at runtime

   # Core settings
   NGINX_WORKER_PROCESSES=auto
   NGINX_WORKER_CONNECTIONS=1024

   # Proxy settings
   PROXY_CONNECT_TIMEOUT=60s
   PROXY_SEND_TIMEOUT=60s
   PROXY_READ_TIMEOUT=60s
   PROXY_BUFFER_SIZE=4k
   PROXY_BUFFERS=4 4k

   # Default backend namespace (if not specified in routes)
   DEFAULT_BACKEND_NAMESPACE=${CURRENT_NAMESPACE}

   # Logging
   LOG_LEVEL=info
   ACCESS_LOG_FORMAT=combined
   ```

3. **Dynamic Configuration Loading**
   - ConfigMap volume mounting
   - Template processing with envsubst
   - Configuration validation
   - Reload without downtime

### Phase 3: Kubernetes Integration (Week 2)
1. **Namespace-Aware Deployment**
   - **REQUIRED**: Target namespace parameter (`DEPLOY_NAMESPACE`)
   - Namespace-specific ConfigMaps
   - Environment variable for current namespace injection
   - Resource limits and requests
   - Liveness and readiness probes
   - ConfigMap volume mounts
   - Security context

2. **Service Definition**
   - ClusterIP for internal access
   - Named ports for clarity
   - Session affinity options
   - Namespace-scoped service discovery

3. **RBAC Setup** (if needed)
   - ServiceAccount creation
   - Role and RoleBinding for config access
   - Cross-namespace service discovery permissions

### Phase 4: Management Tooling (Week 2-3)
1. **Management Script Features**
   ```bash
   ./manage.sh build                      # Build Docker image
   ./manage.sh push                       # Push to registry
   ./manage.sh deploy -n <namespace>      # Deploy to specific namespace (REQUIRED)
   ./manage.sh update-routes -n <namespace> # Update route configuration
   ./manage.sh test -n <namespace>        # Run test suite in namespace
   ./manage.sh logs -n <namespace>        # View gateway logs
   ./manage.sh reload -n <namespace>      # Reload NGINX configuration
   ./manage.sh status -n <namespace>      # Check deployment status
   ./manage.sh uninstall -n <namespace>   # Remove gateway from namespace
   ```

2. **Configuration Validation**
   - YAML syntax checking
   - Route conflict detection
   - Backend service verification

3. **Registry Support**
   - Docker Hub
   - Google Container Registry
   - AWS ECR
   - Self-hosted registries

### Phase 5: Testing Infrastructure (Week 3)
1. **Test Services**
   - Echo service (HTTP)
   - WebSocket echo service
   - Mock REST API
   - Slow response service (timeout testing)

2. **Test Scenarios**
   - Basic routing validation
   - Path prefix stripping
   - WebSocket upgrade
   - Cross-namespace routing
   - Error handling (404, 502, 504)
   - Load balancing behavior

3. **Automated Testing**
   - CI/CD integration
   - Pre-deployment validation
   - Smoke tests
   - Performance benchmarks

### Phase 6: Production Readiness (Week 4)
1. **Monitoring and Observability**
   - Prometheus metrics endpoint
   - Access log analysis
   - Error rate tracking
   - Latency measurements

2. **Security Hardening**
   - Security headers
   - Rate limiting
   - IP whitelisting (optional)
   - TLS termination (optional)

3. **Documentation**
   - API reference
   - Configuration guide
   - Troubleshooting guide
   - Migration guide

## Configuration Examples

### Namespace-Aware Route Configuration
```yaml
# ConfigMap: nginx-gateway-routes
# Deployed to namespace: developer-workspace
metadata:
  namespace: developer-workspace  # Gateway's deployment namespace

routes:
  # Service in same namespace (implicit)
  - prefix: /api/myapp
    backend: myapp-service  # Resolves to myapp-service.developer-workspace.svc.cluster.local
    strip_prefix: false

  # Service in same namespace (explicit)
  - prefix: /api/users
    backend:
      service: user-service
      # namespace omitted = uses gateway's namespace
      port: 8080

  # Cross-namespace routing to dev environment
  - prefix: /api/billing
    backend:
      service: billing-service
      namespace: dev  # Explicit namespace
      port: 3000
    strip_prefix: true

  # WebSocket service in same namespace
  - prefix: /ws/notifications
    backend: notification-service  # Same namespace
    websocket: true

  # Service with custom timeout
  - prefix: /api/reports
    backend: reporting-service.default.svc.cluster.local:8080
    timeout: 120s
    strip_prefix: true
```

### Advanced Configuration with Explicit Namespacing
```yaml
# Gateway deployed to: developer-jane
routes:
  # Local service in developer's namespace
  - prefix: /api/v1/myfeature
    backend:
      service: myfeature-service
      # No namespace = uses 'developer-jane'
      port: 8080
    strip_prefix: true

  # Shared service in dev namespace
  - prefix: /api/v1/products
    backend:
      service: product-service
      namespace: dev  # Explicit cross-namespace
      port: 8080
    strip_prefix: true
    headers:
      add:
        X-Gateway-Version: "1.0"
        X-Forwarded-Prefix: "/api/v1/products"
      remove:
        - X-Debug-Token
    timeout:
      connect: 10s
      send: 60s
      read: 60s
    retry:
      attempts: 3
      on: ["error", "timeout", "http_502", "http_503"]
```

## Usage Examples

### Local Development with Namespace Deployment
```bash
# Deploy the gateway to developer's namespace (REQUIRED)
./manage.sh deploy -n developer-john

# Port-forward to local machine from specific namespace
kubectl port-forward -n developer-john svc/nginx-gateway 8080:80

# Access services in same namespace
curl http://localhost:8080/api/myapp/health  # -> myapp-service.developer-john
curl http://localhost:8080/api/users/list    # -> user-service.developer-john

# Access services in other namespaces (if configured)
curl http://localhost:8080/api/billing/invoice  # -> billing-service.dev
wscat -c ws://localhost:8080/ws/notifications   # -> notification-service.developer-john
```

### Route Updates with Namespace Context
```bash
# Edit routes configuration in specific namespace
kubectl edit configmap nginx-gateway-routes -n developer-john

# Or use the management script with namespace
./manage.sh update-routes -n developer-john routes.yaml

# Reload NGINX without downtime in specific namespace
./manage.sh reload -n developer-john

# View current routes
kubectl get configmap nginx-gateway-routes -n developer-john -o yaml
```

## Testing Strategy

### Unit Tests
- NGINX configuration syntax validation
- Template rendering verification
- Environment variable substitution

### Integration Tests
```bash
# Deploy test services
kubectl apply -f tests/test-services/

# Run routing tests
./tests/integration/routing-test.sh

# Test WebSocket connections
./tests/integration/websocket-test.sh

# Cleanup
kubectl delete -f tests/test-services/
```

### Load Testing
```javascript
// k6 load test example
import http from 'k6/http';
import { check } from 'k6';

export let options = {
  stages: [
    { duration: '30s', target: 100 },
    { duration: '1m', target: 100 },
    { duration: '30s', target: 0 },
  ],
};

export default function() {
  let response = http.get('http://nginx-gateway/api/users');
  check(response, {
    'status is 200': (r) => r.status === 200,
    'response time < 500ms': (r) => r.timings.duration < 500,
  });
}
```

## Security Considerations

### Network Security
- Network policies for pod-to-pod communication
- Ingress/egress rules
- Service mesh integration (optional)

### Application Security
```nginx
# Security headers
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "no-referrer-when-downgrade" always;
```

### Authentication/Authorization
- JWT validation (optional)
- OAuth2 proxy integration (optional)
- API key validation (optional)

## Performance Optimization

### NGINX Tuning
```nginx
# Worker processes
worker_processes auto;
worker_rlimit_nofile 65535;

# Events
events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}

# HTTP settings
http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    keepalive_requests 100;

    # Compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css application/json application/javascript;
}
```

### Resource Limits
```yaml
resources:
  requests:
    memory: "64Mi"
    cpu: "100m"
  limits:
    memory: "256Mi"
    cpu: "500m"
```

## Monitoring and Observability

### Metrics Endpoint
```nginx
location /metrics {
    access_log off;
    stub_status on;
    allow 127.0.0.1;
    deny all;
}
```

### Logging Configuration
```nginx
log_format json_combined escape=json
  '{'
    '"time_local":"$time_local",'
    '"remote_addr":"$remote_addr",'
    '"request":"$request",'
    '"status": "$status",'
    '"body_bytes_sent":"$body_bytes_sent",'
    '"request_time":"$request_time",'
    '"http_referrer":"$http_referer",'
    '"http_user_agent":"$http_user_agent",'
    '"upstream_addr":"$upstream_addr",'
    '"upstream_response_time":"$upstream_response_time",'
    '"namespace":"$CURRENT_NAMESPACE",'
    '"gateway_instance":"nginx-gateway-$CURRENT_NAMESPACE"'
  '}';

access_log /var/log/nginx/access.log json_combined;
```

## Troubleshooting Guide

### Common Issues

1. **502 Bad Gateway**
   - Check service DNS resolution
   - Verify namespace and service names
   - Check backend service health

2. **504 Gateway Timeout**
   - Increase proxy timeout values
   - Check backend service performance
   - Review network policies

3. **WebSocket Connection Failed**
   - Verify upgrade headers
   - Check WebSocket configuration
   - Test with wscat tool

### Debug Commands with Namespace Context
```bash
# Check gateway logs in specific namespace
kubectl logs -f deployment/nginx-gateway -n developer-john

# Test DNS resolution for same-namespace service
kubectl exec deployment/nginx-gateway -n developer-john -- nslookup myapp-service.developer-john.svc.cluster.local

# Test DNS resolution for cross-namespace service
kubectl exec deployment/nginx-gateway -n developer-john -- nslookup billing-service.dev.svc.cluster.local

# Check NGINX configuration
kubectl exec deployment/nginx-gateway -n developer-john -- nginx -T

# Port-forward for direct testing
kubectl port-forward deployment/nginx-gateway -n developer-john 8080:80

# Check environment variables
kubectl exec deployment/nginx-gateway -n developer-john -- env | grep NAMESPACE
```

## Future Enhancements

### Phase 7: Advanced Features (Future)
1. **Circuit Breaker Pattern**
   - Failure detection
   - Automatic recovery
   - Fallback responses

2. **Rate Limiting**
   - Per-client limits
   - Per-route limits
   - Distributed rate limiting

3. **Caching**
   - Response caching
   - Cache invalidation
   - Cache warming

4. **Service Mesh Integration**
   - Istio compatibility
   - Linkerd support
   - Consul Connect

5. **Dynamic Configuration**
   - Hot reload without restart
   - A/B testing support
   - Canary deployments

## Success Criteria

1. **Functional Requirements**
   - ✅ **Namespace-aware deployment** with required namespace parameter
   - ✅ **Intelligent routing** prioritizing same-namespace services
   - ✅ Routes HTTP requests based on path prefix
   - ✅ Supports WebSocket connections
   - ✅ Configurable via ConfigMap with namespace context
   - ✅ Works with kubectl port-forward from any namespace
   - ✅ Cross-namespace routing with explicit configuration

2. **Non-Functional Requirements**
   - ✅ < 100ms added latency
   - ✅ > 99.9% availability
   - ✅ < 100MB memory footprint
   - ✅ < 5 second startup time
   - ✅ Graceful configuration reload

3. **Operational Requirements**
   - ✅ Easy deployment process
   - ✅ Clear documentation
   - ✅ Comprehensive logging
   - ✅ Health check endpoints
   - ✅ Automated testing

## Timeline

- **Week 1**: Core NGINX setup and basic routing
- **Week 2**: Kubernetes integration and configuration management
- **Week 3**: Testing infrastructure and management tooling
- **Week 4**: Documentation and production readiness

## Dependencies

- Kubernetes cluster (1.19+)
- Docker registry access
- kubectl configured
- Basic networking knowledge
- NGINX configuration experience (helpful)

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Complex NGINX configuration | High | Provide templates and examples |
| Service discovery issues | Medium | Comprehensive DNS testing |
| Performance bottlenecks | Medium | Load testing and tuning |
| Configuration errors | Low | Validation and testing tools |

## Deployment Scenarios

### Developer Workspace Isolation
```yaml
# Each developer gets their own namespace with gateway
Namespaces:
  - developer-john    # John's isolated workspace
  - developer-jane    # Jane's isolated workspace
  - developer-bob     # Bob's isolated workspace
  - dev              # Shared development services
  - staging          # Staging environment services
```

### Example Multi-Developer Setup
```bash
# John deploys his gateway
./manage.sh deploy -n developer-john

# John's routing configuration
# - /api/myfeature -> myfeature-service.developer-john (his local service)
# - /api/users -> user-service.dev (shared dev service)
# - /api/billing -> billing-service.staging (staging service)

# Jane deploys her gateway
./manage.sh deploy -n developer-jane

# Jane's routing configuration
# - /api/newui -> newui-service.developer-jane (her local service)
# - /api/users -> user-service.dev (shared dev service)
# - /api/products -> product-service.dev (shared dev service)
```

## Conclusion

This namespace-aware NGINX API gateway provides a powerful solution for developers working with microservices in Kubernetes. By requiring a deployment namespace and supporting intelligent routing between namespaces, it enables:

1. **Developer isolation**: Each developer can have their own gateway instance in their namespace
2. **Service debugging**: Easy access to services in the same namespace for debugging
3. **Microservice integration**: Seamless routing to shared services in other namespaces
4. **Configuration flexibility**: Route definitions that understand namespace context

The design prioritizes developer experience while maintaining production-ready features like health checks, logging, and monitoring, all with namespace awareness built into the core architecture.