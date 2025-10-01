#!/bin/bash
# k8s.sh - Kubernetes operations for NGINX Dev Gateway

# Source common utilities if not already sourced
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -z "$COMMON_SOURCED" ] && source "$SCRIPT_DIR/common.sh"

# Deploy gateway to Kubernetes
deploy_gateway() {
    local namespace="${1:-$NAMESPACE}"
    local k8s_dir="${2:-k8s/base}"

    check_namespace || return 1
    check_kubectl || return 1
    ensure_namespace_exists "$namespace" || return 1

    log_info "Deploying NGINX Dev Gateway to namespace: $namespace"

    # Apply ConfigMap
    if [ -f "$k8s_dir/configmap.yaml" ]; then
        log_info "Applying ConfigMap..."
        kubectl apply -f "$k8s_dir/configmap.yaml" -n "$namespace" || return 1
    fi

    # Apply Deployment
    if [ -f "$k8s_dir/deployment.yaml" ]; then
        log_info "Applying Deployment..."
        kubectl apply -f "$k8s_dir/deployment.yaml" -n "$namespace" || return 1

        # Update image if registry is specified
        local full_image=$(get_full_image)
        if [ -n "$REGISTRY" ]; then
            log_info "Updating deployment image to: $full_image"
            kubectl set image deployment/"$DEFAULT_DEPLOYMENT" \
                nginx="$full_image" -n "$namespace" || log_warning "Failed to update image"
        fi
    fi

    # Apply Service
    if [ -f "$k8s_dir/service.yaml" ]; then
        log_info "Applying Service..."
        kubectl apply -f "$k8s_dir/service.yaml" -n "$namespace" || return 1
    fi

    # Wait for deployment to be ready
    wait_for_deployment "$namespace" || return 1

    log_info "Gateway deployed successfully"
    log_info "To access the gateway, run: manage.sh port-forward -n $namespace 8000"
    return 0
}

# Wait for deployment to be ready
wait_for_deployment() {
    local namespace="${1:-$NAMESPACE}"
    local deployment="${2:-$DEFAULT_DEPLOYMENT}"
    local timeout="${3:-60}"

    log_info "Waiting for deployment to be ready (timeout: ${timeout}s)..."

    if kubectl rollout status deployment/"$deployment" \
        -n "$namespace" \
        --timeout="${timeout}s" 2>/dev/null; then
        log_info "Deployment is ready"
        return 0
    else
        log_error "Deployment failed to become ready within ${timeout}s"
        kubectl get pods -n "$namespace" -l app=nginx-gateway
        return 1
    fi
}

# Get gateway logs
get_logs() {
    local namespace="${1:-$NAMESPACE}"
    local follow="${2:-false}"
    local tail="${3:-50}"
    local selector="app=nginx-gateway"

    check_namespace || return 1
    check_kubectl || return 1

    local pods=$(get_pod_names "$namespace" "$selector")
    if [ -z "$pods" ]; then
        log_error "No gateway pods found in namespace: $namespace"
        return 1
    fi

    local pod=$(echo "$pods" | awk '{print $1}')
    log_info "Showing logs from pod: $pod"

    local log_args="--tail=$tail"
    [ "$follow" = "true" ] && log_args="$log_args -f"

    kubectl logs "$pod" -n "$namespace" $log_args
}

# Get deployment status
get_status() {
    local namespace="${1:-$NAMESPACE}"

    check_namespace || return 1
    check_kubectl || return 1

    echo "=== Deployment Status ==="
    kubectl get deployment "$DEFAULT_DEPLOYMENT" -n "$namespace" 2>/dev/null || echo "Deployment not found"

    echo -e "\n=== Pods Status ==="
    kubectl get pods -n "$namespace" -l app=nginx-gateway 2>/dev/null || echo "No pods found"

    echo -e "\n=== Service Status ==="
    kubectl get service "$DEFAULT_SERVICE" -n "$namespace" 2>/dev/null || echo "Service not found"

    echo -e "\n=== ConfigMap Status ==="
    kubectl get configmap "$DEFAULT_CONFIGMAP" -n "$namespace" 2>/dev/null || echo "ConfigMap not found"

    # Check if pods are ready
    local ready_pods=$(kubectl get pods -n "$namespace" -l app=nginx-gateway \
        --field-selector=status.phase=Running -o name 2>/dev/null | wc -l)

    if [ "$ready_pods" -gt 0 ]; then
        echo -e "\n✅ Gateway is running and ready"
        echo "Ready pods: $ready_pods"
    else
        echo -e "\n⚠️  No ready pods found"
    fi
}

# Port forward to gateway
port_forward() {
    local namespace="${1:-$NAMESPACE}"
    local local_port="${2:-8000}"
    local remote_port="${3:-8000}"

    check_namespace || return 1
    check_kubectl || return 1

    # Check if deployment exists
    if ! resource_exists deployment "$DEFAULT_DEPLOYMENT" "$namespace"; then
        log_error "Deployment not found in namespace: $namespace"
        log_info "Deploy first: manage.sh deploy -n $namespace"
        return 1
    fi

    # Check if service exists
    if ! resource_exists service "$DEFAULT_SERVICE" "$namespace"; then
        log_warning "Service not found, using deployment instead"
        log_info "Port forwarding from deployment/$DEFAULT_DEPLOYMENT ${local_port}:${remote_port}"
        kubectl port-forward deployment/"$DEFAULT_DEPLOYMENT" \
            "${local_port}:${remote_port}" -n "$namespace"
    else
        log_info "Port forwarding from service/$DEFAULT_SERVICE ${local_port}:${remote_port}"
        kubectl port-forward service/"$DEFAULT_SERVICE" \
            "${local_port}:${remote_port}" -n "$namespace"
    fi
}

# Reload NGINX configuration
reload_nginx() {
    local namespace="${1:-$NAMESPACE}"

    check_namespace || return 1
    check_kubectl || return 1

    local pods=$(get_pod_names "$namespace")
    if [ -z "$pods" ]; then
        log_error "No gateway pods found in namespace: $namespace"
        return 1
    fi

    log_info "Reloading NGINX configuration..."

    # Force kubelet to sync ConfigMap by bumping pod annotation
    log_info "Forcing ConfigMap sync..."
    for pod in $pods; do
        kubectl annotate pod "$pod" -n "$namespace" configmap-reload="$(date +%s)" --overwrite 2>/dev/null || true
    done

    # Give kubelet a moment to detect the annotation change and sync ConfigMap
    sleep 3

    # Re-process templates and reload NGINX without restarting pods
    local success=0
    local reload_success=0
    for pod in $pods; do
        log_info "Processing routes for pod: $pod"

        # Re-process route templates from ConfigMap
        if kubectl exec "$pod" -n "$namespace" -- /docker-entrypoint.sh process-routes 2>/dev/null; then
            log_info "Routes processed successfully"

            # Reload NGINX to pick up new configuration
            if kubectl exec "$pod" -n "$namespace" -- nginx -s reload 2>/dev/null; then
                log_info "Pod $pod reloaded successfully"
                success=$((success + 1))
                reload_success=$((reload_success + 1))
            else
                log_error "Failed to reload NGINX on pod: $pod"
            fi
        else
            log_error "Failed to process routes on pod: $pod"
        fi
    done

    if [ "$reload_success" -gt 0 ]; then
        log_info "Successfully reloaded $reload_success pod(s) without restart"
        return 0
    else
        log_error "Failed to reload any pods"
        return 1
    fi
}

# Test NGINX configuration
test_nginx_config() {
    local namespace="${1:-$NAMESPACE}"

    check_namespace || return 1
    check_kubectl || return 1

    local pods=$(get_pod_names "$namespace")
    if [ -z "$pods" ]; then
        log_error "No gateway pods found in namespace: $namespace"
        return 1
    fi

    local pod=$(echo "$pods" | awk '{print $1}')
    log_info "Testing NGINX configuration in pod: $pod"

    if kubectl exec "$pod" -n "$namespace" -- nginx -t 2>&1; then
        log_info "NGINX configuration is valid"
        return 0
    else
        log_error "NGINX configuration test failed"
        return 1
    fi
}

# Uninstall gateway
uninstall_gateway() {
    local namespace="${1:-$NAMESPACE}"
    local k8s_dir="${2:-k8s/base}"

    check_namespace || return 1
    check_kubectl || return 1

    if ! confirm "Remove NGINX Dev Gateway from namespace '$namespace'?" "n"; then
        log_info "Uninstall cancelled"
        return 1
    fi

    log_info "Uninstalling NGINX Dev Gateway from namespace: $namespace"

    # Delete resources
    kubectl delete -f "$k8s_dir/service.yaml" -n "$namespace" 2>/dev/null || true
    kubectl delete -f "$k8s_dir/deployment.yaml" -n "$namespace" 2>/dev/null || true
    kubectl delete -f "$k8s_dir/configmap.yaml" -n "$namespace" 2>/dev/null || true

    # Wait for pods to terminate
    log_info "Waiting for pods to terminate..."
    kubectl wait --for=delete pod -l app=nginx-gateway \
        -n "$namespace" --timeout=30s 2>/dev/null || true

    log_info "Gateway uninstalled from namespace: $namespace"
}

# Scale deployment
scale_deployment() {
    local namespace="${1:-$NAMESPACE}"
    local replicas="${2:-1}"

    check_namespace || return 1
    check_kubectl || return 1

    log_info "Scaling deployment to $replicas replica(s)"

    if kubectl scale deployment/"$DEFAULT_DEPLOYMENT" \
        --replicas="$replicas" -n "$namespace"; then
        log_info "Deployment scaled successfully"
        wait_for_deployment "$namespace"
        return 0
    else
        log_error "Failed to scale deployment"
        return 1
    fi
}

# Restart deployment (trigger rolling update)
restart_deployment() {
    local namespace="${1:-$NAMESPACE}"

    check_namespace || return 1
    check_kubectl || return 1

    log_info "Restarting deployment in namespace: $namespace"

    if kubectl rollout restart deployment/"$DEFAULT_DEPLOYMENT" -n "$namespace"; then
        log_info "Deployment restart initiated"
        wait_for_deployment "$namespace"
        return 0
    else
        log_error "Failed to restart deployment"
        return 1
    fi
}

# Get events related to gateway
get_events() {
    local namespace="${1:-$NAMESPACE}"

    check_namespace || return 1
    check_kubectl || return 1

    log_info "Recent events in namespace: $namespace"

    kubectl get events -n "$namespace" \
        --sort-by='.lastTimestamp' \
        --field-selector involvedObject.name="$DEFAULT_DEPLOYMENT" \
        2>/dev/null || log_info "No events found"

    echo -e "\n=== Pod Events ==="
    local pods=$(get_pod_names "$namespace")
    for pod in $pods; do
        echo "Events for pod: $pod"
        kubectl get events -n "$namespace" \
            --field-selector involvedObject.name="$pod" \
            --sort-by='.lastTimestamp' \
            2>/dev/null || echo "No events"
    done
}

# Execute command in gateway pod
exec_in_pod() {
    local namespace="${1:-$NAMESPACE}"
    shift
    local command="$@"

    check_namespace || return 1
    check_kubectl || return 1

    local pods=$(get_pod_names "$namespace")
    if [ -z "$pods" ]; then
        log_error "No gateway pods found in namespace: $namespace"
        return 1
    fi

    local pod=$(echo "$pods" | awk '{print $1}')
    log_info "Executing in pod: $pod"

    kubectl exec "$pod" -n "$namespace" -- $command
}