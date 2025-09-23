#!/bin/bash
set -e

echo "Starting NGINX Dev Gateway..."
echo "Namespace: ${CURRENT_NAMESPACE:-not set}"

# Create temp directory if it doesn't exist (for volume mounts)
mkdir -p /tmp/nginx 2>/dev/null || true

# Get namespace from Kubernetes if not set
if [ -z "${CURRENT_NAMESPACE}" ]; then
    if [ -f /var/run/secrets/kubernetes.io/serviceaccount/namespace ]; then
        export CURRENT_NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
        echo "Detected namespace from Kubernetes: ${CURRENT_NAMESPACE}"
    else
        export CURRENT_NAMESPACE="default"
        echo "Using default namespace: ${CURRENT_NAMESPACE}"
    fi
fi

# Export required environment variables with defaults
export NGINX_WORKER_PROCESSES=${NGINX_WORKER_PROCESSES:-auto}
export NGINX_WORKER_CONNECTIONS=${NGINX_WORKER_CONNECTIONS:-1024}
export LOG_LEVEL=${LOG_LEVEL:-warn}
export ACCESS_LOG_FORMAT=${ACCESS_LOG_FORMAT:-main}
export PROXY_CONNECT_TIMEOUT=${PROXY_CONNECT_TIMEOUT:-60s}
export PROXY_SEND_TIMEOUT=${PROXY_SEND_TIMEOUT:-60s}
export PROXY_READ_TIMEOUT=${PROXY_READ_TIMEOUT:-60s}
export PROXY_BUFFER_SIZE=${PROXY_BUFFER_SIZE:-4k}
export PROXY_BUFFERS=${PROXY_BUFFERS:-"8 4k"}

# Process nginx.conf template
echo "Processing nginx.conf template..."
envsubst < /etc/nginx/nginx.conf.template > /tmp/nginx/nginx.conf
# Copy to final location
cp /tmp/nginx/nginx.conf /etc/nginx/nginx.conf 2>/dev/null || cat /tmp/nginx/nginx.conf > /etc/nginx/nginx.conf

# Process default.conf template
echo "Processing default.conf template..."
envsubst < /etc/nginx/conf.d/default.conf.template > /tmp/nginx/default.conf
# Copy to final location
cp /tmp/nginx/default.conf /etc/nginx/conf.d/default.conf 2>/dev/null || cat /tmp/nginx/default.conf > /etc/nginx/conf.d/default.conf

# Process proxy.conf template with specific environment variables only
echo "Processing proxy.conf template..."
envsubst '${PROXY_CONNECT_TIMEOUT} ${PROXY_SEND_TIMEOUT} ${PROXY_READ_TIMEOUT} ${PROXY_BUFFER_SIZE} ${PROXY_BUFFERS} ${CURRENT_NAMESPACE}' \
    < /etc/nginx/includes/proxy.conf.template > /etc/nginx/includes/proxy.conf

echo "Proxy and websocket configurations ready"

# Process route configuration files if they exist
if [ -d /etc/nginx/routes ] && [ "$(ls -A /etc/nginx/routes 2>/dev/null)" ]; then
    echo "Processing route configuration files..."
    for template in /etc/nginx/routes/*.template; do
        if [ -f "$template" ]; then
            output_file="${template%.template}"
            echo "Processing $template -> $output_file"
            envsubst '${CURRENT_NAMESPACE}' < "$template" > "$output_file"
        fi
    done
else
    echo "No route configuration files found in /etc/nginx/routes"
fi

# Test nginx configuration
echo "Testing NGINX configuration..."
nginx -t

# Start nginx
echo "Starting NGINX..."
exec "$@"