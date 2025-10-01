#!/bin/bash

# NGINX Dev Gateway Management Script
# Enhanced version with modular libraries

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all library modules
LIB_DIR="${SCRIPT_DIR}/scripts/lib"

# Check if libraries exist
if [ ! -d "$LIB_DIR" ]; then
    echo "Error: Library directory not found: $LIB_DIR"
    echo "Please ensure the scripts/lib directory exists with required modules"
    exit 1
fi

# Source libraries
source "$LIB_DIR/common.sh"
export COMMON_SOURCED=1

source "$LIB_DIR/docker.sh"
export DOCKER_SOURCED=1

source "$LIB_DIR/k8s.sh"
export K8S_SOURCED=1

source "$LIB_DIR/config.sh"
export CONFIG_SOURCED=1

source "$LIB_DIR/validation.sh"
export VALIDATION_SOURCED=1

# Script metadata
readonly VERSION="2.0.0"
readonly SCRIPT_NAME=$(basename "$0")

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--namespace)
                export NAMESPACE="$2"
                shift 2
                ;;
            -r|--registry)
                export REGISTRY="$2"
                shift 2
                ;;
            -i|--image)
                export IMAGE_NAME="$2"
                shift 2
                ;;
            -t|--tag)
                export IMAGE_TAG="$2"
                shift 2
                ;;
            -d|--debug)
                export DEBUG=1
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                echo "$SCRIPT_NAME version $VERSION"
                exit 0
                ;;
            -*)
                # If no further arguments, might be a typo for help
                if [ $# -eq 1 ]; then
                    log_error "Unknown option: $1"
                    show_help
                    exit 1
                fi
                # Otherwise break to let command handler deal with it
                break
                ;;
            *)
                break
                ;;
        esac
    done

    # Return remaining arguments
    echo "$@"
}

# Show help message
show_help() {
    cat << EOF
NGINX Dev Gateway Management Script v$VERSION

Usage: $SCRIPT_NAME [OPTIONS] COMMAND [ARGS]

OPTIONS:
    -n, --namespace NAMESPACE   Kubernetes namespace (or set NAMESPACE env var)
    -r, --registry REGISTRY     Docker registry URL (or set REGISTRY env var)
    -i, --image IMAGE           Docker image name (default: nginx-dev-gateway)
    -t, --tag TAG               Docker image tag (default: latest)
    -d, --debug                 Enable debug output
    -v, --version              Show version
    -h, --help                 Show this help message

COMMANDS:
    === Docker Operations ===
    build                      Build the Docker image
    push                       Push image to registry
    scan                       Scan image for vulnerabilities

    === Kubernetes Operations ===
    deploy                     Deploy gateway to namespace
    uninstall                  Remove gateway from namespace
    status                     Show deployment status
    logs [OPTIONS]             Show gateway logs
        --follow|-f            Follow log output
        --tail N               Number of lines to show
    scale REPLICAS            Scale deployment replicas
    restart                   Restart deployment
    exec COMMAND              Execute command in pod

    === Configuration ===
    update-routes [FILE]       Update route configuration
    backup-routes [DIR]        Backup current routes
    restore-routes [FILE]      Restore routes from backup
    diff-routes FILE          Show diff between current and new routes
    list-routes               List current routes
    export-routes [FILE]      Export routes to file
    generate-routes           Generate basic routes template
    discover-routes [OPTIONS]  Auto-discover services and generate routes
        --stable-namespace NS  Namespace for stable services (default: default)
        --debug-services LIST  Comma-separated services to debug
    switch-service NAME [MODE] Toggle service between debug/stable
        MODE: debug|stable|toggle (default: toggle)
    update-env KEY=VAL...     Update environment variables
    get-env                   Show current environment variables

    === Port Forwarding ===
    port-forward [LOCAL:REMOTE]  Forward local port to gateway (default: 8000:8000)
    pf                          Alias for port-forward

    === Validation & Testing ===
    validate                   Run comprehensive validation
    test [TYPE]               Run test suite
        all                   Run all tests (default)
        deployment           Test deployment
        routes               Test route configuration
        backends             Test backend services
        nginx                Test NGINX configuration
    check-dns SERVICE         Check DNS resolution
    check-backend SERVICE     Test backend connectivity

    === Maintenance ===
    reload                    Reload NGINX configuration
    cleanup                   Clean up old Docker images
    events                    Show Kubernetes events
    backup-all               Backup all configurations

EXAMPLES:
    # Deploy to namespace
    $SCRIPT_NAME -n dev-team deploy

    # Build and push with registry
    $SCRIPT_NAME -r myregistry.io/org build push deploy -n dev-team

    # Discover services and generate routes
    $SCRIPT_NAME -n dev-john discover-routes --debug-services payment-service,order-service

    # Switch a service to debug version
    $SCRIPT_NAME -n dev-john switch-service payment-service debug

    # Update routes
    $SCRIPT_NAME -n dev-team update-routes my-routes.conf

    # Validate configuration
    $SCRIPT_NAME -n dev-team validate

    # Run tests
    $SCRIPT_NAME -n dev-team test all

    # Port forward
    $SCRIPT_NAME -n dev-team port-forward 8000:8000

ENVIRONMENT VARIABLES:
    NAMESPACE               Default namespace for operations
    REGISTRY               Docker registry URL
    IMAGE_NAME             Docker image name (default: nginx-dev-gateway)
    IMAGE_TAG              Docker image tag (default: latest)
    DEBUG                  Enable debug output (0/1)

For more information, see: https://github.com/your-org/nginx-dev-gateway

EOF
}

# Main command handler
main() {
    # Parse global options
    REMAINING_ARGS=$(parse_args "$@")
    set -- $REMAINING_ARGS

    # Get command
    local command="${1:-help}"
    shift || true

    # Handle commands
    case "$command" in
        # Docker operations
        build)
            build_image "$@"
            ;;
        push)
            push_image "$@"
            ;;
        scan)
            scan_image "$@"
            ;;

        # Kubernetes operations
        deploy)
            deploy_gateway "$@"
            ;;
        uninstall)
            uninstall_gateway "$@"
            ;;
        status)
            get_status "$@"
            ;;
        logs)
            # Parse logs options
            local follow=false
            local tail=50
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    -f|--follow)
                        follow=true
                        shift
                        ;;
                    --tail)
                        tail="$2"
                        shift 2
                        ;;
                    *)
                        break
                        ;;
                esac
            done
            get_logs "$NAMESPACE" "$follow" "$tail"
            ;;
        scale)
            scale_deployment "$NAMESPACE" "$@"
            ;;
        restart)
            restart_deployment "$@"
            ;;
        exec)
            exec_in_pod "$NAMESPACE" "$@"
            ;;

        # Configuration
        update-routes)
            update_routes "$NAMESPACE" "$@"
            ;;
        backup-routes)
            backup_routes "$NAMESPACE" "$@"
            ;;
        restore-routes)
            restore_routes "$NAMESPACE" "$@"
            ;;
        diff-routes)
            diff_routes "$NAMESPACE" "$@"
            ;;
        list-routes)
            list_routes "$@"
            ;;
        export-routes)
            export_routes "$NAMESPACE" "$@"
            ;;
        generate-routes)
            generate_route_template "$@"
            ;;
        discover-routes)
            # Parse additional arguments
            local stable_ns="default"
            local debug_svcs=""
            local output_file=""
            local strip_prefix="true"  # Default: strip prefix
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --stable-namespace)
                        stable_ns="$2"
                        shift 2
                        ;;
                    --debug-services)
                        debug_svcs="$2"
                        shift 2
                        ;;
                    --strip-prefix)
                        strip_prefix="true"
                        shift
                        ;;
                    --no-strip-prefix)
                        strip_prefix="false"
                        shift
                        ;;
                    *)
                        # This should be the output file
                        output_file="$1"
                        shift
                        ;;
                esac
            done
            generate_routes_from_discovery "$output_file" "$stable_ns" "$debug_svcs" "$strip_prefix"
            ;;
        switch-service)
            switch_service "$@"
            ;;
        update-env)
            update_env "$NAMESPACE" "$@"
            ;;
        get-env)
            get_env_config "$@"
            ;;

        # Port forwarding
        port-forward|pf)
            # Parse port specification
            local ports="${1:-8000:8000}"
            local local_port=$(echo "$ports" | cut -d: -f1)
            local remote_port=$(echo "$ports" | cut -d: -f2)
            port_forward "$NAMESPACE" "$local_port" "$remote_port"
            ;;

        # Validation & testing
        validate)
            validate_all "$@"
            ;;
        test)
            run_tests "$NAMESPACE" "$@"
            ;;
        check-dns)
            check_dns_resolution "$NAMESPACE" "$@"
            ;;
        check-backend)
            test_backend_connectivity "$NAMESPACE" "$@"
            ;;

        # Maintenance
        reload)
            reload_nginx "$@"
            ;;
        cleanup)
            cleanup_images "$@"
            ;;
        events)
            get_events "$@"
            ;;
        backup-all)
            log_info "Backing up all configurations..."
            backup_routes "$NAMESPACE"
            kubectl get deployment "$DEFAULT_DEPLOYMENT" -n "$NAMESPACE" -o yaml > "backups/deployment-$(date +%Y%m%d_%H%M%S).yaml"
            kubectl get service "$DEFAULT_SERVICE" -n "$NAMESPACE" -o yaml > "backups/service-$(date +%Y%m%d_%H%M%S).yaml"
            log_info "Backup complete"
            ;;

        # Help
        help|--help|-h)
            show_help
            ;;

        # Version
        version|--version|-v)
            echo "$SCRIPT_NAME version $VERSION"
            ;;

        *)
            log_error "Unknown command: $command"
            echo "Run '$SCRIPT_NAME help' for usage information"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"