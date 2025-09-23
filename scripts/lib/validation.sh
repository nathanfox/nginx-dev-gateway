#!/bin/bash
# validation.sh - Validation functions for NGINX Dev Gateway

# Source common utilities if not already sourced
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -z "$COMMON_SOURCED" ] && source "$SCRIPT_DIR/common.sh"
[ -z "$K8S_SOURCED" ] && source "$SCRIPT_DIR/k8s.sh"
[ -z "$CONFIG_SOURCED" ] && source "$SCRIPT_DIR/config.sh"

# Comprehensive validation
validate_all() {
    local namespace="${1:-$NAMESPACE}"
    local errors=0

    check_namespace || return 1
    check_kubectl || return 1

    log_info "Running comprehensive validation for namespace: $namespace"

    echo "=== Deployment Validation ==="
    if validate_deployment "$namespace"; then
        echo "✅ Deployment is valid"
    else
        echo "❌ Deployment validation failed"
        errors=$((errors + 1))
    fi

    echo -e "\n=== Service Validation ==="
    if validate_services "$namespace"; then
        echo "✅ Services are valid"
    else
        echo "❌ Service validation failed"
        errors=$((errors + 1))
    fi

    echo -e "\n=== Route Configuration Validation ==="
    if validate_route_config "$namespace"; then
        echo "✅ Routes are valid"
    else
        echo "❌ Route validation failed"
        errors=$((errors + 1))
    fi

    echo -e "\n=== NGINX Configuration Validation ==="
    if test_nginx_config "$namespace"; then
        echo "✅ NGINX configuration is valid"
    else
        echo "❌ NGINX configuration is invalid"
        errors=$((errors + 1))
    fi

    echo -e "\n=== Backend Service Validation ==="
    if validate_backend_services "$namespace"; then
        echo "✅ Backend services are accessible"
    else
        echo "❌ Some backend services are not accessible"
        errors=$((errors + 1))
    fi

    if [ "$errors" -eq 0 ]; then
        log_info "✅ All validations passed"
        return 0
    else
        log_error "❌ Validation failed with $errors error(s)"
        return 1
    fi
}

# Validate deployment
validate_deployment() {
    local namespace="${1:-$NAMESPACE}"

    if ! resource_exists deployment "$DEFAULT_DEPLOYMENT" "$namespace"; then
        log_error "Deployment not found: $DEFAULT_DEPLOYMENT"
        return 1
    fi

    # Check if deployment is ready
    local ready=$(kubectl get deployment "$DEFAULT_DEPLOYMENT" -n "$namespace" \
        -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)

    if [ "$ready" != "True" ]; then
        log_error "Deployment is not ready"
        kubectl get deployment "$DEFAULT_DEPLOYMENT" -n "$namespace"
        return 1
    fi

    # Check for running pods
    local running_pods=$(kubectl get pods -n "$namespace" -l app=nginx-gateway \
        --field-selector=status.phase=Running -o name 2>/dev/null | wc -l)

    if [ "$running_pods" -eq 0 ]; then
        log_error "No running pods found"
        return 1
    fi

    log_debug "Deployment validation passed"
    return 0
}

# Validate services
validate_services() {
    local namespace="${1:-$NAMESPACE}"

    if ! resource_exists service "$DEFAULT_SERVICE" "$namespace"; then
        log_error "Service not found: $DEFAULT_SERVICE"
        return 1
    fi

    # Check if service has endpoints
    local endpoints=$(kubectl get endpoints "$DEFAULT_SERVICE" -n "$namespace" \
        -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)

    if [ -z "$endpoints" ]; then
        log_error "Service has no endpoints"
        return 1
    fi

    log_debug "Service validation passed"
    return 0
}

# Validate route configuration
validate_route_config() {
    local namespace="${1:-$NAMESPACE}"

    if ! resource_exists configmap "$DEFAULT_CONFIGMAP" "$namespace"; then
        log_error "ConfigMap not found: $DEFAULT_CONFIGMAP"
        return 1
    fi

    # Get route configuration
    local routes=$(kubectl get configmap "$DEFAULT_CONFIGMAP" -n "$namespace" \
        -o jsonpath='{.data.example-routes\.conf}' 2>/dev/null)

    if [ -z "$routes" ]; then
        log_warning "No routes configured"
        return 0
    fi

    # Save to temp file for validation
    local temp_file="/tmp/routes-validate-$$.conf"
    echo "$routes" > "$temp_file"

    # Validate syntax
    if validate_routes_file "$temp_file"; then
        rm -f "$temp_file"
        return 0
    else
        rm -f "$temp_file"
        return 1
    fi
}

# Validate backend services
validate_backend_services() {
    local namespace="${1:-$NAMESPACE}"
    local errors=0

    # Get routes from ConfigMap
    local routes=$(kubectl get configmap "$DEFAULT_CONFIGMAP" -n "$namespace" \
        -o jsonpath='{.data.example-routes\.conf}' 2>/dev/null)

    if [ -z "$routes" ]; then
        log_warning "No routes to validate"
        return 0
    fi

    # Extract backend services from proxy_pass directives
    local backends=$(echo "$routes" | grep -oE 'proxy_pass[[:space:]]+https?://[^;]+' | \
        sed 's/proxy_pass[[:space:]]*http[s]*:\/\///' | \
        sed 's/:[0-9]*.*$//' | \
        sed 's/\.svc\.cluster\.local$//' | \
        sort -u)

    if [ -z "$backends" ]; then
        log_warning "No backend services found in routes"
        return 0
    fi

    log_info "Validating backend services..."

    for backend in $backends; do
        # Parse service name and namespace
        if [[ "$backend" == *"."* ]]; then
            local service_name=$(echo "$backend" | cut -d. -f1)
            local service_ns=$(echo "$backend" | cut -d. -f2)
        else
            local service_name="$backend"
            local service_ns="$namespace"
        fi

        # Replace ${CURRENT_NAMESPACE} with actual namespace
        service_ns="${service_ns//\$\{CURRENT_NAMESPACE\}/$namespace}"

        # Check if service exists
        if kubectl get service "$service_name" -n "$service_ns" >/dev/null 2>&1; then
            # Check if service has endpoints
            local endpoints=$(kubectl get endpoints "$service_name" -n "$service_ns" \
                -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)

            if [ -n "$endpoints" ]; then
                echo "✅ $service_name.$service_ns - OK (endpoints: $(echo $endpoints | wc -w))"
            else
                echo "⚠️  $service_name.$service_ns - No endpoints"
                errors=$((errors + 1))
            fi
        else
            echo "❌ $service_name.$service_ns - Service not found"
            errors=$((errors + 1))
        fi
    done

    if [ "$errors" -eq 0 ]; then
        log_info "All backend services are valid"
        return 0
    else
        log_error "$errors backend service(s) have issues"
        return 1
    fi
}

# Detect route conflicts
detect_route_conflicts() {
    local routes_file="${1:-}"
    local namespace="${2:-$NAMESPACE}"

    if [ -n "$routes_file" ] && [ -f "$routes_file" ]; then
        local routes=$(cat "$routes_file")
    else
        # Get current routes from ConfigMap
        local routes=$(kubectl get configmap "$DEFAULT_CONFIGMAP" -n "$namespace" \
            -o jsonpath='{.data.example-routes\.conf}' 2>/dev/null)
    fi

    if [ -z "$routes" ]; then
        log_warning "No routes to check"
        return 0
    fi

    log_info "Checking for route conflicts..."

    # Extract location patterns
    local locations=$(echo "$routes" | grep '^[[:space:]]*location' | sed 's/^[[:space:]]*//')

    # Check for exact duplicates
    local duplicates=$(echo "$locations" | sort | uniq -d)
    if [ -n "$duplicates" ]; then
        log_error "Duplicate location blocks found:"
        echo "$duplicates"
        return 1
    fi

    # Check for overlapping patterns
    local patterns=$(echo "$locations" | awk '{print $2}' | sed 's/{$//')
    local conflicts=0

    while IFS= read -r pattern1; do
        while IFS= read -r pattern2; do
            if [ "$pattern1" != "$pattern2" ]; then
                # Check if patterns might conflict
                if [[ "$pattern1" == "$pattern2"* ]] || [[ "$pattern2" == "$pattern1"* ]]; then
                    log_warning "Potential conflict: $pattern1 vs $pattern2"
                    conflicts=$((conflicts + 1))
                fi
            fi
        done <<< "$patterns"
    done <<< "$patterns"

    if [ "$conflicts" -gt 0 ]; then
        log_warning "Found $conflicts potential route conflicts"
        return 1
    fi

    log_info "No route conflicts detected"
    return 0
}

# Validate YAML syntax
validate_yaml() {
    local file="$1"

    if [ ! -f "$file" ]; then
        log_error "File not found: $file"
        return 1
    fi

    # Try yq if available
    if command_exists yq; then
        if yq eval '.' "$file" >/dev/null 2>&1; then
            log_debug "YAML validation passed (yq)"
            return 0
        else
            log_error "YAML validation failed"
            return 1
        fi
    fi

    # Try python if available
    if command_exists python3; then
        if python3 -c "import yaml; yaml.safe_load(open('$file'))" 2>/dev/null; then
            log_debug "YAML validation passed (python)"
            return 0
        else
            log_error "YAML validation failed"
            return 1
        fi
    fi

    # Try kubectl dry-run
    if command_exists kubectl; then
        if kubectl apply --dry-run=client -f "$file" >/dev/null 2>&1; then
            log_debug "YAML validation passed (kubectl)"
            return 0
        else
            log_error "YAML validation failed"
            return 1
        fi
    fi

    log_warning "No YAML validator found (install yq or python3-yaml)"
    return 2
}

# Check DNS resolution
check_dns_resolution() {
    local namespace="${1:-$NAMESPACE}"
    local service="${2:-}"

    check_namespace || return 1
    check_kubectl || return 1

    if [ -z "$service" ]; then
        log_error "Service name required"
        return 1
    fi

    # Get a running pod to execute DNS test
    local pod=$(get_pod_names "$namespace" | awk '{print $1}')
    if [ -z "$pod" ]; then
        log_error "No running pods found"
        return 1
    fi

    log_info "Testing DNS resolution for: $service"

    # Try to resolve the service
    if kubectl exec "$pod" -n "$namespace" -- nslookup "$service" 2>/dev/null | grep -q "Address"; then
        log_info "✅ DNS resolution successful"
        kubectl exec "$pod" -n "$namespace" -- nslookup "$service" 2>/dev/null | grep "Address"
        return 0
    else
        log_error "❌ DNS resolution failed"
        return 1
    fi
}

# Test connectivity to backend service
test_backend_connectivity() {
    local namespace="${1:-$NAMESPACE}"
    local backend="${2:-}"
    local port="${3:-80}"

    check_namespace || return 1
    check_kubectl || return 1

    if [ -z "$backend" ]; then
        log_error "Backend service required"
        return 1
    fi

    # Get a running pod to execute test
    local pod=$(get_pod_names "$namespace" | awk '{print $1}')
    if [ -z "$pod" ]; then
        log_error "No running pods found"
        return 1
    fi

    log_info "Testing connectivity to: $backend:$port"

    # Try to connect using curl
    if kubectl exec "$pod" -n "$namespace" -- \
        curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 \
        "http://$backend:$port/health" 2>/dev/null | grep -qE "^[23]"; then
        log_info "✅ Backend is reachable"
        return 0
    else
        log_error "❌ Cannot reach backend"
        return 1
    fi
}

# Run test suite
run_tests() {
    local namespace="${1:-$NAMESPACE}"
    local test_type="${2:-all}"

    check_namespace || return 1
    check_kubectl || return 1

    log_info "Running test suite for namespace: $namespace"

    local errors=0

    if [ "$test_type" = "all" ] || [ "$test_type" = "deployment" ]; then
        echo "=== Deployment Tests ==="
        validate_deployment "$namespace" || errors=$((errors + 1))
    fi

    if [ "$test_type" = "all" ] || [ "$test_type" = "routes" ]; then
        echo "=== Route Tests ==="
        validate_route_config "$namespace" || errors=$((errors + 1))
        detect_route_conflicts "" "$namespace" || errors=$((errors + 1))
    fi

    if [ "$test_type" = "all" ] || [ "$test_type" = "backends" ]; then
        echo "=== Backend Tests ==="
        validate_backend_services "$namespace" || errors=$((errors + 1))
    fi

    if [ "$test_type" = "all" ] || [ "$test_type" = "nginx" ]; then
        echo "=== NGINX Tests ==="
        test_nginx_config "$namespace" || errors=$((errors + 1))
    fi

    if [ "$errors" -eq 0 ]; then
        log_info "✅ All tests passed"
        return 0
    else
        log_error "❌ $errors test(s) failed"
        return 1
    fi
}