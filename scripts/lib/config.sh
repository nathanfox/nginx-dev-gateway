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
            --from-file="example-routes.conf.template=$routes_file" \
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

# Generate example routes - basic template
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

# Generate routes by discovering services in cluster
generate_routes_from_discovery() {
    local output="${1:-discovered-routes.conf}"
    local dev_namespace="${NAMESPACE:-$(kubectl config view --minify -o jsonpath='{..namespace}')}"
    local stable_namespace="${2:-default}"
    local debug_services="${3:-}"  # Comma-separated list of services to debug
    local strip_prefix="${4:-true}"  # Whether to strip prefix (default: true)

    log_info "Discovering services in cluster..."
    log_info "Developer namespace: $dev_namespace"
    log_info "Stable namespace: $stable_namespace"
    log_info "Path behavior: $([ "$strip_prefix" = "true" ] && echo "STRIP PREFIX" || echo "PRESERVE PATH")"

    # Get services in dev namespace
    local dev_services=$(kubectl get services -n "$dev_namespace" --no-headers 2>/dev/null | awk '{print $1}' | grep -v nginx-gateway || true)

    # Get services in stable namespace
    local stable_services=$(kubectl get services -n "$stable_namespace" --no-headers 2>/dev/null | awk '{print $1}' || true)

    # Start generating config
    cat > "$output" << EOF
# ============================================
# NGINX Dev Gateway Route Configuration
# Generated: $(date)
# Developer namespace: $dev_namespace
# Stable namespace: $stable_namespace
# ============================================

EOF

    # Parse debug services list
    IFS=',' read -ra DEBUG_ARRAY <<< "$debug_services"

    # Helper function to check if service is in debug list
    is_debug_service() {
        local svc="$1"
        for debug_svc in "${DEBUG_ARRAY[@]}"; do
            [ "$svc" == "$debug_svc" ] && return 0
        done
        return 1
    }

    # Add routes for services in dev namespace (ones being debugged)
    if [ -n "$dev_services" ]; then
        cat >> "$output" << EOF
# ============================================
# Services being debugged (in $dev_namespace)
# ============================================

EOF
        for service in $dev_services; do
            # Skip if explicitly marked as stable
            if ! is_debug_service "$service" && [ -n "$debug_services" ]; then
                continue
            fi

            # Get service port
            local port=$(kubectl get service "$service" -n "$dev_namespace" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "8080")

            # Clean service name for path (remove -service suffix if present)
            local path_name="${service%-service}"
            # Replace hyphens with underscores for NGINX variable names
            local var_name="${path_name//-/_}"

            # Determine proxy_pass URL based on strip_prefix setting
            local proxy_pass_url
            local path_comment
            if [ "$strip_prefix" = "true" ]; then
                proxy_pass_url="http://\$${var_name}_upstream/"
                path_comment="# Path behavior: STRIP PREFIX (/api/$path_name/ready -> /ready)"
            else
                proxy_pass_url="http://\$${var_name}_upstream"
                path_comment="# Path behavior: PRESERVE PATH (/api/$path_name/ready -> /api/$path_name/ready)"
            fi

            cat >> "$output" << EOF
# $service - YOUR DEBUG VERSION
$path_comment
location /api/$path_name/ {
    set \$${var_name}_upstream ${service}.\${CURRENT_NAMESPACE}.svc.cluster.local:${port};
    proxy_pass $proxy_pass_url;
    include /etc/nginx/includes/proxy.conf;
}

EOF
        done
    fi

    # Add routes for stable services
    if [ -n "$stable_services" ]; then
        cat >> "$output" << EOF
# ============================================
# Stable services (in $stable_namespace)
# ============================================

EOF
        for service in $stable_services; do
            # Skip if this service is being debugged
            if is_debug_service "$service"; then
                continue
            fi

            # Get service port
            local port=$(kubectl get service "$service" -n "$stable_namespace" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "8080")

            # Clean service name for path
            local path_name="${service%-service}"
            # Replace hyphens with underscores for NGINX variable names
            local var_name="${path_name//-/_}"

            # Determine proxy_pass URL based on strip_prefix setting
            local proxy_pass_url
            local path_comment
            if [ "$strip_prefix" = "true" ]; then
                proxy_pass_url="http://\$${var_name}_upstream/"
                path_comment="# Path behavior: STRIP PREFIX (/api/$path_name/ready -> /ready)"
            else
                proxy_pass_url="http://\$${var_name}_upstream"
                path_comment="# Path behavior: PRESERVE PATH (/api/$path_name/ready -> /api/$path_name/ready)"
            fi

            cat >> "$output" << EOF
# $service - STABLE VERSION
$path_comment
location /api/$path_name/ {
    set \$${var_name}_upstream ${service}.${stable_namespace}.svc.cluster.local:${port};
    proxy_pass $proxy_pass_url;
    include /etc/nginx/includes/proxy.conf;
}

EOF
        done
    fi

    # Add WebSocket routes for common patterns
    cat >> "$output" << 'EOF'
# ============================================
# WebSocket routes (if needed)
# ============================================

# Uncomment and modify as needed:
# location /ws/notifications {
#     set $ws_upstream notification-service.${CURRENT_NAMESPACE}.svc.cluster.local:8080;
#     proxy_pass http://$ws_upstream/;
#     include /etc/nginx/includes/websocket.conf;
# }

EOF

    log_success "Generated routes configuration: $output"
    log_info "Services discovered in $dev_namespace: $(echo $dev_services | wc -w)"
    log_info "Services discovered in $stable_namespace: $(echo $stable_services | wc -w)"
    echo ""
    log_info "Review and edit the generated file, then apply with:"
    echo "  $SCRIPT_NAME update-routes -n $dev_namespace $output"
}

# Switch a service between debug and stable versions
switch_service() {
    local service_name="$1"
    local target="${2:-toggle}"  # "debug", "stable", or "toggle"
    local namespace="${NAMESPACE:-$(kubectl config view --minify -o jsonpath='{..namespace}')}"
    local stable_namespace="${3:-default}"

    if [ -z "$service_name" ]; then
        log_error "Service name is required"
        echo "Usage: $SCRIPT_NAME switch-service <service-name> [debug|stable|toggle] [stable-namespace]"
        return 1
    fi

    # Get current routes
    local current_routes=$(kubectl get configmap nginx-gateway-routes -n "$namespace" -o jsonpath='{.data.example-routes\.conf\.template}' 2>/dev/null || echo "")

    if [ -z "$current_routes" ]; then
        log_error "No routes found in ConfigMap. Generate routes first with 'generate-routes'"
        return 1
    fi

    # Clean service name for path
    local path_name="${service_name%-service}"
    # Replace hyphens with underscores for NGINX variable names
    local var_name="${path_name//-/_}"

    # Determine current state
    local is_debug=false
    if echo "$current_routes" | grep -q "location /api/$path_name/" && \
       echo "$current_routes" | grep -A3 "location /api/$path_name/" | grep -q "\${CURRENT_NAMESPACE}"; then
        is_debug=true
    fi

    # Determine target state
    local switch_to="stable"
    case "$target" in
        debug)
            switch_to="debug"
            ;;
        stable)
            switch_to="stable"
            ;;
        toggle)
            if $is_debug; then
                switch_to="stable"
            else
                switch_to="debug"
            fi
            ;;
        *)
            log_error "Invalid target: $target. Use 'debug', 'stable', or 'toggle'"
            return 1
            ;;
    esac

    log_info "Switching $service_name to $switch_to version..."

    # Create temporary file
    local temp_file=$(mktemp)
    echo "$current_routes" > "$temp_file"

    # Get service port
    local port=""
    if [ "$switch_to" == "debug" ]; then
        port=$(kubectl get service "$service_name" -n "$namespace" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "8080")
    else
        port=$(kubectl get service "$service_name" -n "$stable_namespace" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "8080")
    fi

    # Create new location block
    local new_block=""
    if [ "$switch_to" == "debug" ]; then
        new_block="# $service_name - DEBUG VERSION (in $namespace)
location /api/$path_name/ {
    set \$${var_name}_upstream ${service_name}.\${CURRENT_NAMESPACE}.svc.cluster.local:${port};
    proxy_pass http://\$${var_name}_upstream/;
    include /etc/nginx/includes/proxy.conf;
}"
    else
        new_block="# $service_name - STABLE VERSION (in $stable_namespace)
location /api/$path_name/ {
    set \$${var_name}_upstream ${service_name}.${stable_namespace}.svc.cluster.local:${port};
    proxy_pass http://\$${var_name}_upstream/;
    include /etc/nginx/includes/proxy.conf;
}"
    fi

    # Remove existing block if present (including comments)
    # Use awk to remove the location block and its preceding comment
    awk '
    /^# .*(- DEBUG VERSION|- STABLE VERSION).*$/ {
        if (getline && /^location \/api\/'$path_name'\// ) {
            # Skip until we find the closing brace
            while (getline && !match($0, /^}$/)) { }
            next
        } else {
            print prev
            prev = $0
            next
        }
    }
    /^location \/api\/'$path_name'\// {
        # Skip until we find the closing brace
        while (getline && !match($0, /^}$/)) { }
        next
    }
    { if (NR > 1 && prev) print prev; prev = $0 }
    END { if (prev) print prev }
    ' "$temp_file" > "${temp_file}.tmp" && mv "${temp_file}.tmp" "$temp_file"

    # Add new block
    echo "" >> "$temp_file"
    echo "$new_block" >> "$temp_file"

    # Apply the updated routes
    update_routes "$namespace" "$temp_file"

    # Cleanup
    rm -f "$temp_file"

    log_success "Switched $service_name to $switch_to version"
    log_info "The service is now routing to: $([ "$switch_to" == "debug" ] && echo "$namespace" || echo "$stable_namespace") namespace"
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