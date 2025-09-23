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

## Route Configuration

Routes are defined in the ConfigMap `nginx-gateway-routes`. Edit the default routes:

```bash
# With environment variable
export NAMESPACE=developer-john
./manage.sh update-routes

# Or with flag
./manage.sh update-routes -n developer-john
```

### Example Route Configuration

```nginx
# Route to service in same namespace
location /api/myapp/ {
    proxy_pass http://myapp-service.${CURRENT_NAMESPACE}.svc.cluster.local:8080/;
    include /etc/nginx/includes/proxy.conf;
}

# Route to service in different namespace
location /api/billing/ {
    proxy_pass http://billing-service.dev.svc.cluster.local:3000/;
    include /etc/nginx/includes/proxy.conf;
}

# WebSocket route
location /ws/notifications {
    proxy_pass http://notification-service.${CURRENT_NAMESPACE}.svc.cluster.local:8080;
    include /etc/nginx/includes/websocket.conf;
}

# Route with path rewriting
location ~ ^/svc/([a-z]+)/(.*)$ {
    proxy_pass http://$1-service.${CURRENT_NAMESPACE}.svc.cluster.local:8080/$2;
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
    proxy_pass http://custom-service.${CURRENT_NAMESPACE}.svc.cluster.local:9000/;
    include /etc/nginx/includes/proxy.conf;
}
```

```bash
./manage.sh update-routes -n developer-john my-routes.conf
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
└── tests/                    # Test suites
```

## Contributing

See [docs/api-gateway-plan.md](docs/api-gateway-plan.md) for the detailed implementation plan and architecture design.

## License

MIT License - See LICENSE file for details