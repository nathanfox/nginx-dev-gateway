# Development Workflow Guide

## Overview

In a typical development scenario, you're debugging 1-3 services in your personal namespace while depending on stable versions of other services running in a shared namespace (like `default` or `staging`). This guide explains how to set up the NGINX Dev Gateway for this common pattern.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Your Local Machine                       │
│                                                              │
│  curl http://localhost:8080/api/payment   ──┐               │
│  curl http://localhost:8080/api/users     ──┤               │
│  curl http://localhost:8080/api/orders    ──┤               │
│                                              ▼               │
│                    kubectl port-forward nginx-gateway:8080   │
└─────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────┐
│                      Kubernetes Cluster                     │
│                                                             │
│  ┌────────────────────────────────────────────────────────┐ │
│  │            Your Namespace (e.g., dev-john)             │ │
│  │                                                        │ │
│  │  ┌──────────────┐       ┌─────────────────────┐        │ │
│  │  │ NGINX Gateway│──────▶│  payment-service    │        │ │
│  │  │              │       │  (YOUR DEBUG VERSION)│       │ │
│  │  └──────────────┘       └─────────────────────┘        │ │
│  │         │                                              │ │
│  └─────────┼──────────────────────────────────────────────┘ │
│            │                                                │
│            ▼                                                │
│  ┌────────────────────────────────────────────────────────┐ │
│  │         Default/Staging Namespace (Stable Services)    │ │
│  │                                                        │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌──────────────┐    │ │
│  │  │user-service │  │order-service│  │inventory-svc │    │ │
│  │  │  (STABLE)   │  │  (STABLE)   │  │   (STABLE)   │    │ │
│  │  └─────────────┘  └─────────────┘  └──────────────┘    │ │
│  │                                                        │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

## Step-by-Step Setup

### 1. Identify Your Services

First, understand what services are available in each namespace:

```bash
# Services in YOUR namespace (ones you might be debugging)
kubectl get services -n dev-john --no-headers | awk '{print $1}'
# Example output:
# payment-service
# nginx-gateway

# Services in the stable namespace
kubectl get services -n default --no-headers | awk '{print $1}'
# Example output:
# user-service
# order-service
# inventory-service
# notification-service
# billing-service
```

### 2. Determine Your Debugging Targets

Decide which services you're actively debugging vs. which you need as stable dependencies:

**Debugging** (in your namespace):
- `payment-service` - You're fixing a bug in payment processing

**Stable Dependencies** (in default namespace):
- `user-service` - Need user data
- `order-service` - Need order information
- `inventory-service` - Check stock levels
- All other services

### 3. Create Your Routes Configuration

Create a file `my-routes.conf` with your routing setup:

```nginx
# ============================================
# Services I'm Debugging (in my namespace)
# ============================================

# Payment Service - THE ONE I'M DEBUGGING
location /api/payment/ {
    set $payment_upstream payment-service.${CURRENT_NAMESPACE}.svc.cluster.local:8080;
    proxy_pass http://$payment_upstream/;
    include /etc/nginx/includes/proxy.conf;
}

# ============================================
# Stable Services (in default namespace)
# ============================================

# User Service - STABLE VERSION
location /api/users/ {
    set $users_upstream user-service.default.svc.cluster.local:8080;
    proxy_pass http://$users_upstream/;
    include /etc/nginx/includes/proxy.conf;
}

# Order Service - STABLE VERSION
location /api/orders/ {
    set $orders_upstream order-service.default.svc.cluster.local:8080;
    proxy_pass http://$orders_upstream/;
    include /etc/nginx/includes/proxy.conf;
}

# Inventory Service - STABLE VERSION
location /api/inventory/ {
    set $inventory_upstream inventory-service.default.svc.cluster.local:8080;
    proxy_pass http://$inventory_upstream/;
    include /etc/nginx/includes/proxy.conf;
}

# Notification Service - STABLE VERSION
location /api/notifications/ {
    set $notif_upstream notification-service.default.svc.cluster.local:8080;
    proxy_pass http://$notif_upstream/;
    include /etc/nginx/includes/proxy.conf;
}

# Billing Service - STABLE VERSION
location /api/billing/ {
    set $billing_upstream billing-service.default.svc.cluster.local:8080;
    proxy_pass http://$billing_upstream/;
    include /etc/nginx/includes/proxy.conf;
}
```

### 4. Apply Your Routes

```bash
export NAMESPACE=dev-john
./manage.sh update-routes my-routes.conf
```

### 5. Start the Gateway

```bash
# Start port forwarding
./manage.sh port-forward

# In another terminal, test your routes
curl http://localhost:8080/api/payment/health    # Your debug version
curl http://localhost:8080/api/users/health      # Stable version
curl http://localhost:8080/api/orders/health     # Stable version
```

## Common Scenarios

### Scenario 1: Debugging a Single Service

You're working on the payment service while everything else should use stable versions:

```nginx
# Only payment goes to my namespace
location /api/payment/ {
    set $upstream payment-service.${CURRENT_NAMESPACE}.svc.cluster.local:8080;
    proxy_pass http://$upstream/;
    include /etc/nginx/includes/proxy.conf;
}

# Everything else goes to default namespace
location /api/ {
    # Generic catch-all for other services
    set $service_name $uri;
    set $upstream $service_name.default.svc.cluster.local:8080;
    proxy_pass http://$upstream;
    include /etc/nginx/includes/proxy.conf;
}
```

### Scenario 2: Debugging Service Integration

You're debugging how payment and order services interact:

```nginx
# Both services from my namespace for debugging
location /api/payment/ {
    set $upstream payment-service.${CURRENT_NAMESPACE}.svc.cluster.local:8080;
    proxy_pass http://$upstream/;
    include /etc/nginx/includes/proxy.conf;
}

location /api/orders/ {
    set $upstream order-service.${CURRENT_NAMESPACE}.svc.cluster.local:8080;
    proxy_pass http://$upstream/;
    include /etc/nginx/includes/proxy.conf;
}

# Everything else from default
# ... (other stable services)
```

### Scenario 3: Switching Between Debug and Stable

Sometimes you need to quickly switch a service between debug and stable versions:

```bash
# Create two config files
cat > routes-debug.conf <<EOF
location /api/payment/ {
    set $upstream payment-service.${CURRENT_NAMESPACE}.svc.cluster.local:8080;
    proxy_pass http://$upstream/;
    include /etc/nginx/includes/proxy.conf;
}
EOF

cat > routes-stable.conf <<EOF
location /api/payment/ {
    set $upstream payment-service.default.svc.cluster.local:8080;
    proxy_pass http://$upstream/;
    include /etc/nginx/includes/proxy.conf;
}
EOF

# Switch to debug version
./manage.sh update-routes routes-debug.conf

# Switch back to stable
./manage.sh update-routes routes-stable.conf
```

## Advanced Patterns

### Pattern 1: Namespace Fallback

Try your namespace first, fall back to default if not found:

```nginx
location /api/payment/ {
    # This requires custom Lua scripting or multiple location blocks
    # For now, explicitly specify which namespace to use
    set $upstream payment-service.${CURRENT_NAMESPACE}.svc.cluster.local:8080;
    proxy_pass http://$upstream/;
    include /etc/nginx/includes/proxy.conf;
}
```

### Pattern 2: Environment-Based Routing

Route based on headers to test different versions:

```nginx
location /api/payment/ {
    set $upstream payment-service.default.svc.cluster.local:8080;

    # Override with debug version if header is present
    if ($http_x_debug = "true") {
        set $upstream payment-service.${CURRENT_NAMESPACE}.svc.cluster.local:8080;
    }

    proxy_pass http://$upstream/;
    include /etc/nginx/includes/proxy.conf;
}
```

### Pattern 3: Service Discovery

Use a naming convention to auto-route:

```nginx
# Route /debug/* to your namespace
location ~ ^/debug/([^/]+)/(.*)$ {
    set $service $1-service;
    set $path $2;
    set $upstream $service.${CURRENT_NAMESPACE}.svc.cluster.local:8080;
    proxy_pass http://$upstream/$path$is_args$args;
    include /etc/nginx/includes/proxy.conf;
}

# Route /stable/* to default namespace
location ~ ^/stable/([^/]+)/(.*)$ {
    set $service $1-service;
    set $path $2;
    set $upstream $service.default.svc.cluster.local:8080;
    proxy_pass http://$upstream/$path$is_args$args;
    include /etc/nginx/includes/proxy.conf;
}
```

## Tips and Best Practices

### 1. Document Your Routes
Always add comments explaining which services are debug vs. stable:

```nginx
# DEBUG: Payment service (fixing transaction bug #123)
location /api/payment/ { ... }

# STABLE: User service (not touching this)
location /api/users/ { ... }
```

### 2. Use Consistent Naming
Establish a pattern for your routes:
- `/api/[service]/` for services
- `/ws/[service]` for WebSockets
- `/internal/[service]/` for internal services

### 3. Test Incrementally
Start with routing everything to stable, then move services to debug one at a time:

```bash
# Start with all stable
./manage.sh update-routes all-stable.conf
curl http://localhost:8080/api/payment/health  # Verify it works

# Switch payment to debug
./manage.sh update-routes payment-debug.conf
curl http://localhost:8080/api/payment/health  # Verify debug version
```

### 4. Keep a Stable Baseline
Always keep a configuration that routes everything to stable services:

```bash
# Save your stable configuration
kubectl get configmap nginx-gateway-routes -n dev-john -o yaml > stable-routes-backup.yaml

# Restore if needed
kubectl apply -f stable-routes-backup.yaml
./manage.sh reload
```

### 5. Monitor Service Availability

Before adding routes, verify services exist:

```bash
# Check if service exists in your namespace
kubectl get service payment-service -n dev-john

# Check if service exists in default namespace
kubectl get service user-service -n default
```

## Troubleshooting

### Issue: 502 Bad Gateway

**Cause**: Service doesn't exist in the specified namespace

**Solution**: Verify the service exists:
```bash
kubectl get service [service-name] -n [namespace]
```

### Issue: 404 Not Found

**Cause**: Route not configured

**Solution**: Check your routes are loaded:
```bash
kubectl exec -n dev-john deployment/nginx-gateway -- cat /etc/nginx/routes/your-routes.conf
```

### Issue: Connecting to Wrong Version

**Cause**: Route pointing to wrong namespace

**Solution**: Check the actual configuration:
```bash
kubectl exec -n dev-john deployment/nginx-gateway -- nginx -T | grep -A 5 "location /api/payment"
```

### Issue: Services Can't Find Each Other

**Cause**: Debugging service calling other services directly

**Solution**: Services should call each other through the gateway:
```javascript
// In your payment service
// Instead of: http://user-service:8080/api/users
// Use: http://nginx-gateway/api/users
```

## Quick Reference

### List All Services
```bash
# Your namespace
kubectl get svc -n dev-john

# Stable namespace
kubectl get svc -n default
```

### Update Routes
```bash
./manage.sh update-routes my-routes.conf
```

### Test Route
```bash
curl -v http://localhost:8080/api/[service]/health
```

### View Current Routes
```bash
kubectl exec -n dev-john deployment/nginx-gateway -- cat /etc/nginx/routes/*.conf
```

### Reload Configuration
```bash
./manage.sh reload
```

## Conclusion

The NGINX Dev Gateway shines in this mixed-namespace scenario, allowing you to:
1. Debug your services in isolation
2. Depend on stable versions of other services
3. Quickly switch between debug and stable versions
4. Access everything through a single `kubectl port-forward`

This setup mirrors real-world development where you're focused on specific services while the rest of the system remains stable.