# NGINX Dev Gateway - Example Route Configurations

This directory contains example route configurations for common development scenarios. These examples demonstrate various routing patterns and use cases for the NGINX Dev Gateway.

## Examples Overview

### 🎯 Basic Scenarios

#### [single-debug-service.conf](./single-debug-service.conf)
Most common scenario - debugging one service while using stable versions of everything else.
- Debug: payment-service (your namespace)
- Stable: all other services (default namespace)

```bash
./manage.sh -n dev-john update-routes examples/single-debug-service.conf
```

#### [multiple-debug-services.conf](./multiple-debug-services.conf)
Debugging integration between multiple services.
- Debug: payment-service, order-service (your namespace)
- Stable: all other services (default namespace)

```bash
./manage.sh update-routes -n dev-john examples/multiple-debug-services.conf
```

#### [microservices-all-stable.conf](./microservices-all-stable.conf)
Baseline configuration with all services from stable namespace.
- All services from default namespace
- Good starting point before switching individual services to debug

```bash
./manage.sh update-routes -n dev-john examples/microservices-all-stable.conf
```

### 🔧 Advanced Patterns

#### [mixed-local-cluster.conf](./mixed-local-cluster.conf)
Running some services locally on your machine.
- Local: Frontend (React), Backend API
- Debug: payment-service (your namespace)
- Stable: other services (default namespace)

```bash
./manage.sh update-routes -n dev-john examples/mixed-local-cluster.conf
```

#### [websocket-services.conf](./websocket-services.conf)
Services using WebSocket connections for real-time features.
- WebSocket endpoints for chat, notifications, dashboard
- Socket.io specific routing
- Regular HTTP endpoints alongside WebSocket

```bash
./manage.sh update-routes -n dev-john examples/websocket-services.conf
```

#### [path-rewriting.conf](./path-rewriting.conf)
URL path transformation examples.
- Strip prefixes (`/svc/billing/invoice` → `/invoice`)
- Add prefixes (`/users` → `/api/users`)
- Version routing (`/v1/orders` vs `/v2/orders`)
- Dynamic service routing based on path

```bash
./manage.sh update-routes -n dev-john examples/path-rewriting.conf
```

#### [header-based-routing.conf](./header-based-routing.conf)
Route based on request headers.
- Debug mode with `X-Debug: true`
- Multi-tenancy with `X-Tenant-Id`
- A/B testing with `X-Experiment`
- Mock responses with `X-Mock: true`

```bash
./manage.sh update-routes -n dev-john examples/header-based-routing.conf
# Test with: curl -H "X-Debug: true" http://localhost:8080/api/payment/
```

## Quick Start Guide

### 1. Choose Your Scenario

```bash
# See what's in your namespace
kubectl get svc -n $NAMESPACE

# See what's in stable namespace
kubectl get svc -n default
```

### 2. Generate Routes Automatically

```bash
# Discover services and generate routes
./manage.sh discover-routes -n dev-john \
  --stable-namespace default \
  --debug-services payment-service,order-service
```

### 3. Or Use an Example

```bash
# Copy and modify an example
cp examples/single-debug-service.conf my-routes.conf
vim my-routes.conf

# Apply your configuration
./manage.sh update-routes -n dev-john my-routes.conf
```

### 4. Switch Services Dynamically

```bash
# Switch payment-service to debug version
./manage.sh switch-service -n dev-john payment-service debug

# Switch back to stable
./manage.sh switch-service -n dev-john payment-service stable

# Toggle between debug and stable
./manage.sh switch-service -n dev-john payment-service toggle
```

## Important Notes

### DNS Resolution Pattern
Always use variables in `proxy_pass` for Kubernetes services:

```nginx
# ✅ CORRECT - Runtime DNS resolution
location /api/service/ {
    set $upstream service.namespace.svc.cluster.local:8080;
    proxy_pass http://$upstream/;
}

# ❌ WRONG - DNS resolved at startup
location /api/service/ {
    proxy_pass http://service.namespace.svc.cluster.local:8080/;
}
```

### Namespace Variables
- `${CURRENT_NAMESPACE}` - Replaced with gateway's namespace at runtime
- Use explicit namespace for stable services (e.g., `default`, `staging`)

### WebSocket Routes
Must include proper upgrade headers:

```nginx
location /ws/endpoint {
    set $ws_upstream service.namespace.svc.cluster.local:8080;
    proxy_pass http://$ws_upstream/;

    # Required for WebSocket
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_buffering off;

    # Long timeouts for persistent connections
    proxy_connect_timeout 7d;
    proxy_send_timeout 7d;
    proxy_read_timeout 7d;
}
```

## Common Patterns

### Service Naming Convention
Most examples assume services follow naming pattern:
- Service name: `payment-service`
- URL path: `/api/payment/` (without -service suffix)

### Port Convention
Examples assume port 8080 for most services. Adjust as needed for your services.

### Testing Routes

```bash
# Test a route
curl http://localhost:8080/api/payment/health

# Test with debug header
curl -H "X-Debug: true" http://localhost:8080/api/payment/

# Test WebSocket
wscat -c ws://localhost:8080/ws/notifications
```

## Tips

1. **Start Simple**: Begin with all services stable, then switch to debug one at a time
2. **Use Discovery**: Let the tool discover your services automatically
3. **Keep Backups**: Save working configurations before making changes
4. **Test Incrementally**: Verify each route works before adding more
5. **Document Your Routes**: Add comments explaining which services are debug vs stable

## Need Help?

- See [Development Workflow Guide](../docs/development-workflow.md) for detailed explanations
- Check [Routing Guide](../docs/routing-guide.md) for technical details
- Run `./manage.sh help` for command reference