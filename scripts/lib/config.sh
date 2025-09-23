#!/bin/bash
# config.sh - Configuration management for NGINX Dev Gateway

# Source common utilities if not already sourced
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -z "$COMMON_SOURCED" ] && source "$SCRIPT_DIR/common.sh"

# Update route configuration
update_routes() {
    local namespace="${1:-$NAMESPACE}"
    local routes_file="${2:-}"

    check_namespace || return 1
    check_kubectl || return 1

    if [ -n "$routes_file" ]; then
        if [ ! -f "$routes_file" ]; then
            log_error "Routes file not found: $routes_file"
            return 1
        fi

        # Validate the routes file first
        if ! validate_routes_file "$routes_file"; then
            log_error "Route validation failed"
            return 1
        fi

        log_info "Updating routes from file: $routes_file"

        # Create ConfigMap from file
        kubectl create configmap "$DEFAULT_CONFIGMAP" \
            --from-file="example-routes.conf=$routes_file" \
            --dry-run=client -o yaml | \
            kubectl apply -f - -n "$namespace"
    else
        log_info "Opening ConfigMap for editing..."
        kubectl edit configmap "$DEFAULT_CONFIGMAP" -n "$namespace"
    fi

    # Trigger reload after update
    log_info "Reloading NGINX configuration..."
    reload_nginx "$namespace"
}

# Backup current routes
backup_routes() {
    local namespace="${1:-$NAMESPACE}"
    local backup_dir="${2:-backups}"
    local timestamp=$(date +%Y%m%d_%H%M%S)

    check_namespace || return 1
    check_kubectl || return 1

    ensure_dir "$backup_dir"

    local backup_file="${backup_dir}/routes-${namespace}-${timestamp}.yaml"

    log_info "Backing up routes to: $backup_file"

    if kubectl get configmap "$DEFAULT_CONFIGMAP" -n "$namespace" -o yaml > "$backup_file"; then
        log_info "Routes backed up successfully"
        echo "$backup_file"
        return 0
    else
        log_error "Failed to backup routes"
        return 1
    fi
}

# Restore routes from backup
restore_routes() {
    local namespace="${1:-$NAMESPACE}"
    local backup_file="${2:-}"

    check_namespace || return 1
    check_kubectl || return 1

    if [ -z "$backup_file" ]; then
        # Show available backups
        local backup_dir="backups"
        if [ -d "$backup_dir" ]; then
            log_info "Available backups:"
            ls -la "$backup_dir"/routes-*.yaml 2>/dev/null || {
                log_error "No backups found"
                return 1
            }
            echo
            read -p "Enter backup file path: " backup_file
        else
            log_error "No backup directory found"
            return 1
        fi
    fi

    if [ ! -f "$backup_file" ]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi

    if ! confirm "Restore routes from $backup_file to namespace '$namespace'?" "n"; then
        log_info "Restore cancelled"
        return 1
    fi

    # Create current backup before restore
    log_info "Creating backup of current configuration..."
    backup_routes "$namespace" || log_warning "Failed to backup current config"

    log_info "Restoring routes from: $backup_file"

    if kubectl apply -f "$backup_file" -n "$namespace"; then
        log_info "Routes restored successfully"
        reload_nginx "$namespace"
        return 0
    else
        log_error "Failed to restore routes"
        return 1
    fi
}

# Show diff between current and new routes
diff_routes() {
    local namespace="${1:-$NAMESPACE}"
    local new_routes="${2:-}"

    check_namespace || return 1
    check_kubectl || return 1

    if [ -z "$new_routes" ] || [ ! -f "$new_routes" ]; then
        log_error "New routes file required: $new_routes"
        return 1
    fi

    local temp_current="/tmp/routes-current-$$.yaml"
    local temp_new="/tmp/routes-new-$$.yaml"

    # Get current routes
    kubectl get configmap "$DEFAULT_CONFIGMAP" -n "$namespace" \
        -o jsonpath='{.data.example-routes\.conf}' > "$temp_current" 2>/dev/null

    if [ ! -s "$temp_current" ]; then
        log_warning "No existing routes found"
        echo "=== NEW ROUTES ==="
        cat "$new_routes"
    else
        # Prepare new routes
        cp "$new_routes" "$temp_new"

        echo "=== ROUTE CHANGES ==="
        if command_exists diff; then
            diff -u "$temp_current" "$temp_new" || true
        else
            log_warning "diff command not found, showing files side by side"
            echo "CURRENT:"
            cat "$temp_current"
            echo -e "\nNEW:"
            cat "$temp_new"
        fi
    fi

    # Cleanup
    rm -f "$temp_current" "$temp_new"
}

# Generate example routes
generate_route_template() {
    local output="${1:-example-routes.conf}"
    local namespace="${NAMESPACE:-default}"

    cat > "$output" << 'EOF'
# NGINX Dev Gateway Route Configuration
# This file defines routing rules for the gateway

# Example: Route to a service in the same namespace
# The ${CURRENT_NAMESPACE} variable will be replaced with the gateway's namespace
location /api/myservice/ {
    proxy_pass http://myservice.${CURRENT_NAMESPACE}.svc.cluster.local:8080/;
    include /etc/nginx/includes/proxy.conf;
}

# Example: Route to a service in a different namespace
location /api/shared/ {
    proxy_pass http://shared-service.production.svc.cluster.local:8080/;
    include /etc/nginx/includes/proxy.conf;
}

# Example: WebSocket route
location /ws/notifications {
    proxy_pass http://notification-service.${CURRENT_NAMESPACE}.svc.cluster.local:8080;
    include /etc/nginx/includes/websocket.conf;
}

# Example: Route with path rewriting
# Removes the /svc/billing prefix when proxying
location ~ ^/svc/billing/(.*)$ {
    proxy_pass http://billing-service.${CURRENT_NAMESPACE}.svc.cluster.local:3000/$1$is_args$args;
    include /etc/nginx/includes/proxy.conf;
}

# Health check endpoint (already defined in main config)
# location /health {
#     access_log off;
#     return 200 "healthy\n";
#     add_header Content-Type text/plain;
# }
EOF

    # Replace namespace variable
    sed -i.bak "s/\${CURRENT_NAMESPACE}/$namespace/g" "$output" && rm "${output}.bak"

    log_info "Generated route template: $output"
    log_info "Edit this file and apply with: manage.sh update-routes -n $namespace $output"
}

# Validate routes file syntax
validate_routes_file() {
    local routes_file="$1"

    if [ ! -f "$routes_file" ]; then
        log_error "Routes file not found: $routes_file"
        return 1
    fi

    # Basic syntax checks
    local errors=0

    # Check for matching braces
    local open_braces=$(grep -c '{' "$routes_file" || echo 0)
    local close_braces=$(grep -c '}' "$routes_file" || echo 0)

    if [ "$open_braces" -ne "$close_braces" ]; then
        log_error "Mismatched braces in routes file"
        errors=$((errors + 1))
    fi

    # Check for duplicate location blocks
    local locations=$(grep '^[[:space:]]*location' "$routes_file" | awk '{print $2}' | sort)
    local duplicates=$(echo "$locations" | uniq -d)

    if [ -n "$duplicates" ]; then
        log_error "Duplicate location blocks found:"
        echo "$duplicates"
        errors=$((errors + 1))
    fi

    # Check for required includes
    if ! grep -q 'include /etc/nginx/includes/' "$routes_file"; then
        log_warning "No proxy.conf or websocket.conf includes found"
    fi

    # Check for valid proxy_pass URLs
    local invalid_urls=$(grep 'proxy_pass' "$routes_file" | grep -v 'http://' | grep -v 'https://' | grep -v '#')
    if [ -n "$invalid_urls" ]; then
        log_error "Invalid proxy_pass URLs (must start with http:// or https://):"
        echo "$invalid_urls"
        errors=$((errors + 1))
    fi

    if [ "$errors" -eq 0 ]; then
        log_info "Routes file validation passed"
        return 0
    else
        log_error "Routes file validation failed with $errors error(s)"
        return 1
    fi
}

# List all routes
list_routes() {
    local namespace="${1:-$NAMESPACE}"

    check_namespace || return 1
    check_kubectl || return 1

    log_info "Current routes in namespace: $namespace"

    kubectl get configmap "$DEFAULT_CONFIGMAP" -n "$namespace" \
        -o jsonpath='{.data.example-routes\.conf}' 2>/dev/null || {
        log_error "No routes found"
        return 1
    }
}

# Export routes to file
export_routes() {
    local namespace="${1:-$NAMESPACE}"
    local output="${2:-routes-export.conf}"

    check_namespace || return 1
    check_kubectl || return 1

    log_info "Exporting routes to: $output"

    kubectl get configmap "$DEFAULT_CONFIGMAP" -n "$namespace" \
        -o jsonpath='{.data.example-routes\.conf}' > "$output" 2>/dev/null

    if [ -s "$output" ]; then
        log_info "Routes exported successfully"
        echo "$output"
        return 0
    else
        log_error "Failed to export routes (no routes found?)"
        rm -f "$output"
        return 1
    fi
}

# Get environment variables configuration
get_env_config() {
    local namespace="${1:-$NAMESPACE}"

    check_namespace || return 1
    check_kubectl || return 1

    log_info "Environment variables in namespace: $namespace"

    kubectl get deployment "$DEFAULT_DEPLOYMENT" -n "$namespace" \
        -o jsonpath='{.spec.template.spec.containers[0].env[*]}' 2>/dev/null | \
        jq -r '.[] | "\(.name)=\(.value)"' 2>/dev/null || {
        kubectl get deployment "$DEFAULT_DEPLOYMENT" -n "$namespace" \
            -o yaml | grep -A1 "env:" | grep -E "name:|value:" || \
            log_error "Failed to get environment configuration"
    }
}

# Update environment variables
update_env() {
    local namespace="${1:-$NAMESPACE}"
    shift
    local env_vars="$@"

    check_namespace || return 1
    check_kubectl || return 1

    if [ -z "$env_vars" ]; then
        log_error "Environment variables required"
        log_info "Usage: manage.sh update-env -n namespace KEY1=value1 KEY2=value2"
        return 1
    fi

    log_info "Updating environment variables..."

    for env_var in $env_vars; do
        if [[ "$env_var" =~ ^[A-Z_]+=[^=]+$ ]]; then
            log_info "Setting: $env_var"
            kubectl set env deployment/"$DEFAULT_DEPLOYMENT" "$env_var" -n "$namespace"
        else
            log_error "Invalid format: $env_var (expected KEY=value)"
        fi
    done

    log_info "Environment variables updated, deployment will restart automatically"
}