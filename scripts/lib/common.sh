#!/bin/bash
# common.sh - Shared utilities for NGINX Dev Gateway management

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Default values
readonly DEFAULT_IMAGE_NAME="nginx-dev-gateway"
readonly DEFAULT_IMAGE_TAG="latest"
readonly DEFAULT_DEPLOYMENT="nginx-gateway"
readonly DEFAULT_SERVICE="nginx-gateway"
readonly DEFAULT_CONFIGMAP="nginx-gateway-routes"

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_debug() {
    if [ "${DEBUG:-0}" = "1" ]; then
        echo -e "${BLUE}[DEBUG]${NC} $*" >&2
    fi
}

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
check_docker() {
    if ! command_exists docker; then
        log_error "Docker is not installed or not in PATH"
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running or not accessible"
        return 1
    fi

    log_debug "Docker check passed"
    return 0
}

check_kubectl() {
    if ! command_exists kubectl; then
        log_error "kubectl is not installed or not in PATH"
        log_info "Install kubectl: https://kubernetes.io/docs/tasks/tools/"
        return 1
    fi

    if ! kubectl version --client >/dev/null 2>&1; then
        log_error "kubectl is not configured properly"
        return 1
    fi

    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "Cannot connect to Kubernetes cluster"
        log_info "Check your kubeconfig and cluster connectivity"
        return 1
    fi

    log_debug "kubectl check passed"
    return 0
}

# Namespace handling
check_namespace() {
    if [ -z "$NAMESPACE" ]; then
        log_error "Namespace is required. Use -n flag or set NAMESPACE environment variable"
        return 1
    fi

    log_debug "Using namespace: $NAMESPACE"
    return 0
}

get_namespace() {
    echo "${NAMESPACE:-}"
}

ensure_namespace_exists() {
    local ns="${1:-$NAMESPACE}"

    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        log_debug "Namespace '$ns' exists"
        return 0
    fi

    log_warning "Namespace '$ns' does not exist"
    read -p "Create namespace '$ns'? (y/N) " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if kubectl create namespace "$ns"; then
            log_info "Namespace '$ns' created"
            return 0
        else
            log_error "Failed to create namespace '$ns'"
            return 1
        fi
    else
        log_error "Namespace '$ns' must exist to continue"
        return 1
    fi
}

# Registry handling
get_registry() {
    echo "${REGISTRY:-}"
}

get_full_image() {
    local image_name="${IMAGE_NAME:-$DEFAULT_IMAGE_NAME}"
    local image_tag="${IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"
    local registry="${REGISTRY:-}"

    if [ -n "$registry" ]; then
        echo "${registry}/${image_name}:${image_tag}"
    else
        echo "${image_name}:${image_tag}"
    fi
}

detect_registry_type() {
    local registry="${1:-$REGISTRY}"

    case "$registry" in
        *azurecr.io*)
            echo "acr"
            ;;
        *gcr.io*)
            echo "gcr"
            ;;
        *amazonaws.com*)
            echo "ecr"
            ;;
        *docker.io* | *dockerhub*)
            echo "dockerhub"
            ;;
        "")
            echo "local"
            ;;
        *)
            echo "generic"
            ;;
    esac
}

# Kubernetes resource checks
resource_exists() {
    local resource_type="$1"
    local resource_name="$2"
    local namespace="${3:-$NAMESPACE}"

    kubectl get "$resource_type" "$resource_name" -n "$namespace" >/dev/null 2>&1
}

get_pod_names() {
    local namespace="${1:-$NAMESPACE}"
    local selector="${2:-app=nginx-gateway}"

    kubectl get pods -n "$namespace" -l "$selector" -o jsonpath='{.items[*].metadata.name}'
}

get_pod_status() {
    local pod_name="$1"
    local namespace="${2:-$NAMESPACE}"

    kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.phase}'
}

wait_for_pod_ready() {
    local namespace="${1:-$NAMESPACE}"
    local selector="${2:-app=nginx-gateway}"
    local timeout="${3:-60}"

    log_info "Waiting for pods to be ready (timeout: ${timeout}s)..."

    if kubectl wait --for=condition=ready pod \
        -l "$selector" \
        -n "$namespace" \
        --timeout="${timeout}s" 2>/dev/null; then
        log_info "Pods are ready"
        return 0
    else
        log_error "Pods failed to become ready within ${timeout}s"
        return 1
    fi
}

# File and directory helpers
ensure_dir() {
    local dir="$1"

    if [ ! -d "$dir" ]; then
        log_debug "Creating directory: $dir"
        mkdir -p "$dir"
    fi
}

backup_file() {
    local file="$1"
    local backup_dir="${2:-backups}"
    local timestamp=$(date +%Y%m%d_%H%M%S)

    if [ ! -f "$file" ]; then
        log_warning "File not found: $file"
        return 1
    fi

    ensure_dir "$backup_dir"

    local basename=$(basename "$file")
    local backup_file="${backup_dir}/${basename}.${timestamp}.bak"

    if cp "$file" "$backup_file"; then
        log_info "Backup created: $backup_file"
        echo "$backup_file"
        return 0
    else
        log_error "Failed to create backup"
        return 1
    fi
}

# Confirmation prompts
confirm() {
    local message="${1:-Are you sure?}"
    local default="${2:-n}"

    local prompt="$message"
    if [ "$default" = "y" ]; then
        prompt="$prompt [Y/n]"
    else
        prompt="$prompt [y/N]"
    fi

    read -p "$prompt " -n 1 -r
    echo

    if [ "$default" = "y" ]; then
        [[ ! $REPLY =~ ^[Nn]$ ]]
    else
        [[ $REPLY =~ ^[Yy]$ ]]
    fi
}

# Version comparison
version_gt() {
    # Returns 0 if version1 > version2
    local version1="$1"
    local version2="$2"

    printf '%s\n%s\n' "$version2" "$version1" | sort -V | head -n1 | grep -q "^$version2$"
}

# Export functions for use by other scripts
export -f log_info log_warning log_error log_debug
export -f command_exists check_docker check_kubectl
export -f check_namespace get_namespace ensure_namespace_exists
export -f get_registry get_full_image detect_registry_type
export -f resource_exists get_pod_names get_pod_status wait_for_pod_ready
export -f ensure_dir backup_file confirm version_gt