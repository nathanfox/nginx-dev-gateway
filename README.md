# NGINX Dev Gateway for Kubernetes

A lightweight, namespace-aware NGINX-based API gateway for Kubernetes that enables developers to access multiple microservices through a single `kubectl port-forward` command.

## Features

- 🚀 **Single Entry Point**: One `kubectl port-forward` to access all services
- 🎯 **Path-Based Routing**: Route requests based on URL paths (`/api/service` → `service`)
- 🔍 **Namespace-Aware**: Automatically routes to services in the same namespace, with support for cross-namespace routing
- 🔄 **WebSocket Support**: Full WebSocket protocol support for real-time applications
- 📝 **ConfigMap-Based Configuration**: Easy route management through Kubernetes ConfigMaps
- 🏃 **Lightweight**: Alpine-based image (~15MB) with minimal resource usage
- 🛠️ **Developer-Friendly**: Simple management script for all operations

## Quick Start

### Prerequisites

- Kubernetes cluster (local or remote)
- `kubectl` configured and connected to your cluster
- Docker (for building the image)

### 1. Build the Docker Image

```bash
./manage.sh build
```

### 2. Push to Registry (Required for Kubernetes)

Kubernetes needs to pull images from a registry. The deployment will automatically use the registry specified in the `REGISTRY` environment variable.

#### Option A: Azure Container Registry (ACR) for AKS
```bash
# Setup ACR (one time only)
az acr create --resource-group <your-rg> --name <your-acr> --sku Basic
az aks update -n <your-aks> -g <your-rg> --attach-acr <your-acr>

# Build, push, and deploy with registry
export REGISTRY=<your-acr>.azurecr.io
export NAMESPACE=developer-john

az acr login --name <your-acr>
./manage.sh build
./manage.sh push
./manage.sh deploy  # Automatically uses $REGISTRY image
```

#### Option B: Docker Hub
```bash
# Build, push, and deploy with Docker Hub
export REGISTRY=docker.io/<your-username>
export NAMESPACE=developer-john

docker login
./manage.sh build
./manage.sh push
./manage.sh deploy  # Automatically uses $REGISTRY image
```

#### Option C: Build directly with ACR (No local Docker needed)
```bash
# Build directly in Azure (no local Docker required)
az acr build --registry <your-acr> --image nginx-dev-gateway:latest .

# Deploy using the ACR image
export REGISTRY=<your-acr>.azurecr.io
export NAMESPACE=developer-john
./manage.sh deploy
```

### 3. Deploy to Your Namespace

If you've already set `REGISTRY` and `NAMESPACE` environment variables above:
```bash
./manage.sh deploy  # Uses $REGISTRY for image and $NAMESPACE for deployment
```

Or specify namespace explicitly:
```bash
./manage.sh deploy -n developer-john
```

### 3. Start Port-Forward

```bash
# With environment variable set
./manage.sh port-forward 8080

# Or with explicit namespace
./manage.sh port-forward -n developer-john 8080
```

### 4. Access Your Services

```bash
# Access services through the gateway
curl http://localhost:8080/api/echo/hello
curl http://localhost:8080/api/users/list
wscat -c ws://localhost:8080/ws/notifications
```

## Typical Development Setup

In most development scenarios, you're debugging 1-3 services in your namespace while using stable versions of other services from a shared namespace:

```
Your Namespace (dev-john):
  - payment-service (debugging)
  - nginx-gateway

Default/Staging Namespace:
  - user-service (stable)
  - order-service (stable)
  - inventory-service (stable)
  - 20+ other services (stable)
```

See [Development Workflow Guide](docs/development-workflow.md) for detailed setup instructions.

### Quick Setup for Your Services

#### Option 1: Automatic Service Discovery (Recommended)

```bash
# Discover services and generate routes automatically
./manage.sh -n $NAMESPACE discover-routes my-routes.conf \
  --stable-namespace default \
  --debug-services payment-service,order-service

# Apply the generated routes
./manage.sh -n $NAMESPACE update-routes my-routes.conf

# Dynamically switch services between debug and stable
./manage.sh -n $NAMESPACE switch-service payment-service debug   # Use debug version
./manage.sh -n $NAMESPACE switch-service payment-service stable  # Use stable version
./manage.sh -n $NAMESPACE switch-service payment-service toggle  # Toggle between versions
```

#### Option 2: Manual Configuration

1. **Discover your services**:
```bash
# See what's in your namespace (services you're debugging)
kubectl get svc -n $NAMESPACE --no-headers | awk '{print $1}'

# See what's in the stable namespace
kubectl get svc -n default --no-headers | awk '{print $1}'
```

2. **Create your routes** (`my-routes.conf`):
```nginx
# Service I'm debugging (in my namespace)
location /api/payment/ {
    set $payment_upstream payment-service.${CURRENT_NAMESPACE}.svc.cluster.local:8080;
    proxy_pass http://$payment_upstream/;
    include /etc/nginx/includes/proxy.conf;
}

# Stable services (in default namespace)
location /api/users/ {
    set $users_upstream user-service.default.svc.cluster.local:8080;
    proxy_pass http://$users_upstream/;
    include /etc/nginx/includes/proxy.conf;
}
```

3. **Apply and test**:
```bash
./manage.sh -n $NAMESPACE update-routes my-routes.conf
curl http://localhost:8080/api/payment/   # Your debug version
curl http://localhost:8080/api/users/     # Stable version
```

## Route Configuration

Routes are defined in the ConfigMap `nginx-gateway-routes`. Edit the default routes:

```bash
# With environment variable
export NAMESPACE=developer-john
./manage.sh update-routes

# Or with flag
./manage.sh -n developer-john update-routes
```

### Example Route Configuration

> **Important**: Always use variables in `proxy_pass` for Kubernetes services to ensure proper DNS resolution. See [Routing Guide](docs/routing-guide.md) for details.

```nginx
# Route to service in same namespace (with runtime DNS resolution)
location /api/myapp/ {
    set $myapp_upstream myapp-service.${CURRENT_NAMESPACE}.svc.cluster.local:8080;
    proxy_pass http://$myapp_upstream/;
    include /etc/nginx/includes/proxy.conf;
}

# Route to service in different namespace
location /api/billing/ {
    set $billing_upstream billing-service.dev.svc.cluster.local:3000;
    proxy_pass http://$billing_upstream/;
    include /etc/nginx/includes/proxy.conf;
}

# WebSocket route (requires special configuration)
location /ws/notifications {
    set $ws_upstream notification-service.${CURRENT_NAMESPACE}.svc.cluster.local:8080;
    proxy_pass http://$ws_upstream/;

    # Required WebSocket headers
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_buffering off;

    # Long timeouts for persistent connections
    proxy_connect_timeout 7d;
    proxy_send_timeout 7d;
    proxy_read_timeout 7d;
}

# Route with path rewriting
location ~ ^/svc/([a-z]+)/(.*)$ {
    set $service_upstream $1-service.${CURRENT_NAMESPACE}.svc.cluster.local:8080;
    proxy_pass http://$service_upstream/$2;
    include /etc/nginx/includes/proxy.conf;
}
```

## Management Commands

All commands support both environment variable and command-line flag for namespace:

```bash
# Set namespace once for all commands
export NAMESPACE=developer-john

# Build Docker image
./manage.sh build

# Deploy to namespace
./manage.sh deploy                      # uses $NAMESPACE
./manage.sh deploy -n other-namespace   # overrides with flag

# Update routes configuration
./manage.sh update-routes [routes-file]

# Auto-discover services and generate routes
./manage.sh discover-routes [output-file] [options]
# Options:
#   --stable-namespace NS    Namespace for stable services (default: default)
#   --debug-services LIST    Comma-separated services to debug

# Switch service between debug and stable versions
./manage.sh switch-service <service-name> [mode]
# Modes: debug, stable, toggle (default: toggle)

# View gateway logs
./manage.sh logs

# Check deployment status
./manage.sh status

# Reload NGINX configuration
./manage.sh reload

# Port-forward to local machine
./manage.sh port-forward [port]

# Run tests
./manage.sh test

# Uninstall from namespace
./manage.sh uninstall
```

### Environment Variables

```bash
export NAMESPACE=developer-john      # Default namespace for operations
export REGISTRY=myregistry.io        # Docker registry URL
export IMAGE_NAME=nginx-dev-gateway  # Docker image name
export IMAGE_TAG=v1.0.0              # Docker image tag
```

## Architecture

The gateway consists of:

1. **NGINX Proxy**: Routes incoming requests to Kubernetes services
2. **ConfigMap**: Stores routing configuration
3. **Namespace Context**: Automatically detects and uses deployment namespace
4. **Service Discovery**: Uses Kubernetes DNS for service resolution

## Use Cases

### Developer Debugging
Each developer gets their own gateway instance in their namespace:

```bash
# John's gateway
./manage.sh deploy -n developer-john
./manage.sh port-forward -n developer-john 8080

# Jane's gateway
./manage.sh deploy -n developer-jane
./manage.sh port-forward -n developer-jane 8081
```

### Microservices Access
Access multiple services through a single port:

```bash
# Instead of multiple port-forwards:
kubectl port-forward svc/user-service 8081:80
kubectl port-forward svc/order-service 8082:80
kubectl port-forward svc/payment-service 8083:80

# Use one gateway:
kubectl port-forward svc/nginx-gateway 8080:80
# Access all services via paths:
# http://localhost:8080/api/users
# http://localhost:8080/api/orders
# http://localhost:8080/api/payments
```

## Advanced Configuration

### Environment Variables

Configure the gateway behavior through environment variables:

```yaml
env:
- name: NGINX_WORKER_PROCESSES
  value: "auto"              # Number of nginx worker processes
- name: NGINX_WORKER_CONNECTIONS
  value: "1024"              # Max connections per worker
- name: LOG_LEVEL
  value: "info"              # Nginx log level (debug, info, notice, warn, error, crit)
- name: PROXY_CONNECT_TIMEOUT
  value: "60s"               # Timeout for connecting to upstream
- name: PROXY_SEND_TIMEOUT
  value: "60s"               # Timeout for sending to upstream
- name: PROXY_READ_TIMEOUT
  value: "60s"               # Timeout for reading from upstream
- name: PROXY_BUFFER_SIZE
  value: "4k"                # Buffer size for proxy responses
- name: PROXY_BUFFERS
  value: "8 4k"              # Number and size of buffers
```

You can also update these values on a running deployment:

```bash
# Update timeout values
kubectl set env deployment/nginx-gateway \
  PROXY_CONNECT_TIMEOUT=30s \
  PROXY_READ_TIMEOUT=120s \
  -n developer-john

# View current environment variables
kubectl get deployment nginx-gateway -n developer-john -o jsonpath='{.spec.template.spec.containers[0].env[*]}' | jq
```

### Custom Routes File

Create a custom routes file and apply it:

```nginx
# my-routes.conf
location /api/custom/ {
    set $custom_upstream custom-service.${CURRENT_NAMESPACE}.svc.cluster.local:9000;
    proxy_pass http://$custom_upstream/;
    include /etc/nginx/includes/proxy.conf;
}
```

```bash
./manage.sh -n developer-john update-routes my-routes.conf
```

## Troubleshooting

### Check Gateway Status
```bash
./manage.sh status -n developer-john
```

### View Logs
```bash
./manage.sh logs -n developer-john
```

### Test Connectivity
```bash
./manage.sh test -n developer-john
```

### Common Issues

1. **502 Bad Gateway**
   - Service doesn't exist or has no endpoints
   - Check service name and namespace
   - Verify service is running: `kubectl get svc -n <namespace>`

2. **Connection Refused**
   - Port-forward not active
   - Run: `./manage.sh port-forward -n <namespace> 8080`

3. **404 Not Found**
   - Route not configured
   - Update routes: `./manage.sh update-routes -n <namespace>`

4. **WebSocket Connection Issues**
   - Ensure using variables in proxy_pass for runtime DNS resolution
   - Check WebSocket headers are properly configured
   - See [Routing Guide](docs/routing-guide.md#websocket-routing) for details

## Project Structure

```
nginx-dev-gateway/
├── Dockerfile                 # Alpine NGINX image
├── manage.sh                  # Management script
├── nginx/
│   ├── nginx.conf.template   # Main NGINX config
│   ├── conf.d/               # Server configurations
│   ├── includes/             # Reusable config snippets
│   └── scripts/              # Container scripts
├── k8s/
│   └── base/                 # Kubernetes manifests
│       ├── configmap.yaml    # Routes configuration
│       ├── deployment.yaml   # Gateway deployment
│       └── service.yaml      # ClusterIP service
├── docs/                     # Documentation
│   ├── api-gateway-plan.md  # Architecture design
│   ├── routing-guide.md      # Routing configuration guide
│   ├── kubectl-setup.md      # kubectl setup guide
│   └── service-discovery.md  # Service discovery patterns
├── tests/                    # Test suites
└── test-services/           # Test service deployments
```

## Documentation

- [Routing Guide](docs/routing-guide.md) - **Essential reading** for configuring routes, especially WebSocket support
- [Architecture Design](docs/api-gateway-plan.md) - Detailed implementation plan
- [Roadmap & Future Enhancements](docs/roadmap.md) - Planned features and improvements
- [kubectl Setup Guide](docs/kubectl-setup.md) - Setting up kubectl aliases and helpers
- [Service Discovery Patterns](docs/service-discovery.md) - Kubernetes service discovery patterns

## Contributing

Contributions are welcome! Please read the documentation above to understand the architecture and routing patterns.

## License

MIT License - See LICENSE file for details