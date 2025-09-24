# NGINX Dev Gateway Routing Guide

## Table of Contents
- [Overview](#overview)
- [DNS Resolution in Kubernetes](#dns-resolution-in-kubernetes)
- [HTTP Routing](#http-routing)
- [WebSocket Routing](#websocket-routing)
- [Common Issues and Solutions](#common-issues-and-solutions)
- [Best Practices](#best-practices)

## Overview

This guide explains how to properly configure routing in the NGINX Dev Gateway for Kubernetes environments, with special attention to DNS resolution and WebSocket support.

## DNS Resolution in Kubernetes

### The Challenge

In Kubernetes, services use DNS names like `service-name.namespace.svc.cluster.local` that resolve to ClusterIP addresses. These IPs can change when:
- Pods restart
- Services are redeployed
- Kubernetes reassigns IPs

### The Problem with Static Resolution

When NGINX uses direct hostnames in `proxy_pass`:

```nginx
# ❌ BAD: DNS resolved at startup only
location /api/ {
    proxy_pass http://api-service.namespace.svc.cluster.local:8080/;
}
```

NGINX resolves the DNS name **once at configuration load time**. If the service IP changes, NGINX continues using the stale IP, causing connection failures.

### The Solution: Runtime Resolution

Force runtime DNS resolution using variables:

```nginx
# ✅ GOOD: DNS resolved at request time
location /api/ {
    set $backend api-service.namespace.svc.cluster.local:8080;
    proxy_pass http://$backend/;
}
```

## HTTP Routing

### Basic HTTP Service Route

```nginx
location /api/ {
    # Use variable for runtime DNS resolution
    set $api_upstream api-service.namespace.svc.cluster.local:8080;
    proxy_pass http://$api_upstream/;

    # Include standard proxy configuration
    include /etc/nginx/includes/proxy.conf;
}
```

### Route with Path Rewriting

```nginx
location /old-api/ {
    set $backend legacy-service.namespace.svc.cluster.local:8080;
    # Rewrite /old-api/foo to /api/foo
    rewrite ^/old-api/(.*)$ /api/$1 break;
    proxy_pass http://$backend;
    include /etc/nginx/includes/proxy.conf;
}
```

## WebSocket Routing

WebSocket routing requires special configuration due to the protocol upgrade mechanism.

### Complete WebSocket Configuration

```nginx
location /ws {
    # Force runtime DNS resolution
    set $ws_upstream websocket-service.namespace.svc.cluster.local:8080;
    proxy_pass http://$ws_upstream/ws;

    # Required: HTTP/1.1 for WebSocket
    proxy_http_version 1.1;

    # Required: WebSocket upgrade headers
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";

    # Standard forwarding headers
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    # Custom headers
    proxy_set_header X-Gateway-Namespace $current_namespace;

    # Required: Disable buffering for real-time communication
    proxy_buffering off;

    # Long timeouts for persistent connections
    proxy_connect_timeout 7d;
    proxy_send_timeout 7d;
    proxy_read_timeout 7d;
}
```

### Why Each WebSocket Setting Matters

| Setting | Purpose | What Happens Without It |
|---------|---------|-------------------------|
| `proxy_http_version 1.1` | WebSocket requires HTTP/1.1 | Connection fails during upgrade |
| `Upgrade: $http_upgrade` | Signals protocol change | No WebSocket handshake |
| `Connection: "upgrade"` | Completes upgrade handshake | Connection rejected |
| `proxy_buffering off` | Real-time bidirectional data | Message delays/buffering |
| Long timeouts | Persistent connections | Premature disconnections |

## Common Issues and Solutions

### Issue 1: WebSocket Connections Timeout

**Symptom:** WebSocket connections hang or timeout when connecting through the gateway.

**Solution:** Ensure you're using variables in `proxy_pass`:
```nginx
# Instead of:
proxy_pass http://websocket-service.namespace.svc.cluster.local:8080/ws;

# Use:
set $ws_upstream websocket-service.namespace.svc.cluster.local:8080;
proxy_pass http://$ws_upstream/ws;
```

### Issue 2: Services Become Unreachable After Restart

**Symptom:** Services work initially but fail after pod restarts.

**Solution:** Configure proper DNS resolver in nginx.conf:
```nginx
http {
    # Kubernetes DNS resolver
    resolver kube-dns.kube-system.svc.cluster.local valid=30s ipv6=off;
    resolver_timeout 10s;
}
```

### Issue 3: Template Variables Not Processed

**Symptom:** Nginx fails with syntax errors about `${VARIABLE}`.

**Solution:** Ensure templates are processed with envsubst:
```bash
# In docker-entrypoint.sh
envsubst '${CURRENT_NAMESPACE}' < /etc/nginx/includes/websocket.conf.template > /etc/nginx/includes/websocket.conf
```

## Best Practices

### 1. Always Use Variables for Kubernetes Services

```nginx
# Good practice for all service proxying
location /service1/ {
    set $upstream1 service1.namespace.svc.cluster.local:8080;
    proxy_pass http://$upstream1/;
}

location /service2/ {
    set $upstream2 service2.namespace.svc.cluster.local:8080;
    proxy_pass http://$upstream2/;
}
```

### 2. Create Reusable Configuration Templates

Create templates for common patterns:

```nginx
# /etc/nginx/templates/websocket-location.template
location LOCATION_PATH {
    set $ws_upstream UPSTREAM_SERVICE;
    proxy_pass http://$ws_upstream/UPSTREAM_PATH;

    # WebSocket configuration
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_buffering off;

    # Timeouts
    proxy_connect_timeout 7d;
    proxy_send_timeout 7d;
    proxy_read_timeout 7d;
}
```

### 3. Test Routes Thoroughly

```bash
# Test HTTP endpoint
curl http://gateway/api/health

# Test WebSocket with wscat
wscat -c ws://gateway/ws

# Test WebSocket upgrade headers
curl -i -N \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==" \
  http://gateway/ws
```

### 4. Monitor and Log

Add logging for debugging:

```nginx
location /ws {
    access_log /var/log/nginx/websocket_access.log;
    error_log /var/log/nginx/websocket_error.log debug;

    set $ws_upstream websocket-service.namespace.svc.cluster.local:8080;
    proxy_pass http://$ws_upstream/;
    # ... rest of configuration
}
```

### 5. Use ConfigMaps for Dynamic Routes

Structure your ConfigMap for easy management:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-gateway-routes
data:
  http-routes.conf: |
    # HTTP Services
    location /api/ {
        set $api api-service.namespace.svc.cluster.local:8080;
        proxy_pass http://$api/;
        include /etc/nginx/includes/proxy.conf;
    }

  websocket-routes.conf: |
    # WebSocket Services
    location /ws {
        set $ws ws-service.namespace.svc.cluster.local:8080;
        proxy_pass http://$ws/;
        # WebSocket headers...
    }
```

## Testing Your Configuration

### 1. Verify DNS Resolution

```bash
# From within the nginx pod
kubectl exec -it nginx-gateway-pod -- nslookup service-name.namespace.svc.cluster.local
```

### 2. Test Service Connectivity

```bash
# Test direct service access from nginx pod
kubectl exec -it nginx-gateway-pod -- curl http://service-name.namespace.svc.cluster.local:8080/health
```

### 3. Validate Nginx Configuration

```bash
# Check nginx configuration syntax
kubectl exec -it nginx-gateway-pod -- nginx -t
```

### 4. Monitor Logs

```bash
# Watch nginx logs
kubectl logs -f nginx-gateway-pod

# Check error logs
kubectl exec -it nginx-gateway-pod -- tail -f /var/log/nginx/error.log
```

## Example: Complete Route Configuration

Here's a complete example showing both HTTP and WebSocket routes:

```nginx
# HTTP API Service
location /api/ {
    set $api_upstream api-service.namespace.svc.cluster.local:8080;
    proxy_pass http://$api_upstream/;
    include /etc/nginx/includes/proxy.conf;
}

# WebSocket Service
location /ws {
    set $ws_upstream websocket-service.namespace.svc.cluster.local:8080;
    proxy_pass http://$ws_upstream/ws;

    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_buffering off;
    proxy_connect_timeout 7d;
    proxy_send_timeout 7d;
    proxy_read_timeout 7d;
}

# Static Assets with Caching
location /static/ {
    set $cdn_upstream cdn-service.namespace.svc.cluster.local:8080;
    proxy_pass http://$cdn_upstream/;
    proxy_cache_valid 200 1h;
    proxy_cache_bypass $http_cache_control;
    add_header X-Cache-Status $upstream_cache_status;
}

# Health Check Endpoint
location /health {
    access_log off;
    default_type application/json;
    return 200 '{"status":"healthy","gateway":"nginx-dev-gateway"}';
}
```

## Troubleshooting Checklist

- [ ] DNS resolver configured in nginx.conf?
- [ ] Using variables in proxy_pass directives?
- [ ] WebSocket headers properly configured?
- [ ] Buffering disabled for WebSocket endpoints?
- [ ] Appropriate timeouts set?
- [ ] Services resolvable from nginx pod?
- [ ] ConfigMaps properly mounted?
- [ ] Nginx configuration syntax valid?
- [ ] Environment variables properly substituted?
- [ ] Logs checked for errors?

## References

- [NGINX WebSocket Proxying](http://nginx.org/en/docs/http/websocket.html)
- [Kubernetes DNS for Services](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)
- [NGINX Reverse Proxy](http://nginx.org/en/docs/http/ngx_http_proxy_module.html)