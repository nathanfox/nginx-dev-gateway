#!/bin/bash
set -e

# Function to set up environment variables
setup_env() {
    # Get namespace from Kubernetes if not set
    if [ -z "${CURRENT_NAMESPACE}" ]; then
        if [ -f /var/run/secrets/kubernetes.io/serviceaccount/namespace ]; then
            export CURRENT_NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
        else
            export CURRENT_NAMESPACE="default"
        fi
    fi

    # Export required environment variables with defaults
    export NGINX_PORT=${NGINX_PORT:-8000}
    export NGINX_WORKER_PROCESSES=${NGINX_WORKER_PROCESSES:-auto}
    export NGINX_WORKER_CONNECTIONS=${NGINX_WORKER_CONNECTIONS:-1024}
    export LOG_LEVEL=${LOG_LEVEL:-warn}
    export ACCESS_LOG_FORMAT=${ACCESS_LOG_FORMAT:-main}
    export PROXY_CONNECT_TIMEOUT=${PROXY_CONNECT_TIMEOUT:-60s}
    export PROXY_SEND_TIMEOUT=${PROXY_SEND_TIMEOUT:-60s}
    export PROXY_READ_TIMEOUT=${PROXY_READ_TIMEOUT:-60s}
    export PROXY_BUFFER_SIZE=${PROXY_BUFFER_SIZE:-4k}
    export PROXY_BUFFERS=${PROXY_BUFFERS:-"8 4k"}
}

# Function to process route configuration files only
process_routes() {
    echo "Re-processing route configuration files..."
    setup_env

    # Create temp directory
    mkdir -p /tmp/nginx/routes

    # Clear existing processed routes
    rm -f /tmp/nginx/routes/*.conf

    if [ -d /etc/nginx/routes ] && [ "$(ls -A /etc/nginx/routes 2>/dev/null)" ]; then
        for template in /etc/nginx/routes/*.template; do
            if [ -f "$template" ]; then
                filename=$(basename "$template" .template)
                output_file="/tmp/nginx/routes/${filename}"
                echo "Processing $template -> $output_file"
                envsubst '${CURRENT_NAMESPACE}' < "$template" > "$output_file"
            fi
        done
        echo "Route processing complete"
    else
        echo "No route configuration files found in /etc/nginx/routes"
    fi
}

# Handle commands
case "${1:-}" in
    process-routes)
        process_routes
        exit 0
        ;;
esac

# Normal startup flow
echo "Starting NGINX Dev Gateway..."
echo "Namespace: ${CURRENT_NAMESPACE:-not set}"

# Create temp directory if it doesn't exist (for volume mounts)
mkdir -p /tmp/nginx 2>/dev/null || true

setup_env
echo "Namespace: ${CURRENT_NAMESPACE}"

# Process nginx.conf template
echo "Processing nginx.conf template..."
envsubst '${NGINX_WORKER_PROCESSES} ${NGINX_WORKER_CONNECTIONS} ${LOG_LEVEL} ${ACCESS_LOG_FORMAT} ${CURRENT_NAMESPACE}' \
    < /etc/nginx/nginx.conf.template > /tmp/nginx/nginx.conf
# Copy to final location
cp /tmp/nginx/nginx.conf /etc/nginx/nginx.conf 2>/dev/null || cat /tmp/nginx/nginx.conf > /etc/nginx/nginx.conf

# Process default.conf template
echo "Processing default.conf template..."
envsubst '${NGINX_PORT} ${CURRENT_NAMESPACE}' < /etc/nginx/conf.d/default.conf.template > /tmp/nginx/default.conf
# Copy to final location
cp /tmp/nginx/default.conf /etc/nginx/conf.d/default.conf 2>/dev/null || cat /tmp/nginx/default.conf > /etc/nginx/conf.d/default.conf

# Process proxy.conf template with specific environment variables only
echo "Processing proxy.conf template..."
envsubst '${PROXY_CONNECT_TIMEOUT} ${PROXY_SEND_TIMEOUT} ${PROXY_READ_TIMEOUT} ${PROXY_BUFFER_SIZE} ${PROXY_BUFFERS} ${CURRENT_NAMESPACE}' \
    < /etc/nginx/includes/proxy.conf.template > /etc/nginx/includes/proxy.conf

# Process websocket.conf template
echo "Processing websocket.conf template..."
envsubst '${CURRENT_NAMESPACE}' \
    < /etc/nginx/includes/websocket.conf.template > /etc/nginx/includes/websocket.conf

echo "Proxy and websocket configurations ready"

# Process route configuration files
process_routes

# Test nginx configuration
echo "Testing NGINX configuration..."
nginx -t

# Start nginx
echo "Starting NGINX..."
exec "$@"