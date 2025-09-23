#!/bin/bash
# docker.sh - Docker operations for NGINX Dev Gateway

# Source common utilities if not already sourced
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -z "$COMMON_SOURCED" ] && source "$SCRIPT_DIR/common.sh"

# Build Docker image
build_image() {
    local dockerfile="${1:-Dockerfile}"
    local context="${2:-.}"
    local image_name="${IMAGE_NAME:-$DEFAULT_IMAGE_NAME}"
    local image_tag="${IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"

    check_docker || return 1

    if [ ! -f "$dockerfile" ]; then
        log_error "Dockerfile not found: $dockerfile"
        return 1
    fi

    log_info "Building Docker image: ${image_name}:${image_tag}"

    if docker build \
        -f "$dockerfile" \
        -t "${image_name}:${image_tag}" \
        ${BUILD_ARGS:+--build-arg $BUILD_ARGS} \
        ${NO_CACHE:+--no-cache} \
        "$context"; then
        log_info "Image built successfully: ${image_name}:${image_tag}"
        return 0
    else
        log_error "Failed to build image"
        return 1
    fi
}

# Push image to registry
push_image() {
    local registry="${1:-$REGISTRY}"
    local image_name="${IMAGE_NAME:-$DEFAULT_IMAGE_NAME}"
    local image_tag="${IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"

    check_docker || return 1

    if [ -z "$registry" ]; then
        log_error "Registry is required for push operation"
        log_info "Set REGISTRY environment variable or pass as argument"
        return 1
    fi

    local full_image="${registry}/${image_name}:${image_tag}"
    local local_image="${image_name}:${image_tag}"

    # Check if local image exists
    if ! docker image inspect "$local_image" >/dev/null 2>&1; then
        log_error "Local image not found: $local_image"
        log_info "Build the image first: manage.sh build"
        return 1
    fi

    # Tag the image for registry
    log_info "Tagging image for registry: $full_image"
    if ! docker tag "$local_image" "$full_image"; then
        log_error "Failed to tag image"
        return 1
    fi

    # Login to registry if needed
    if ! docker_registry_login "$registry"; then
        log_warning "Registry login might have failed, continuing anyway..."
    fi

    # Push the image
    log_info "Pushing image to registry: $full_image"
    if docker push "$full_image"; then
        log_info "Image pushed successfully"
        echo "$full_image"
        return 0
    else
        log_error "Failed to push image"
        return 1
    fi
}

# Registry login helper
docker_registry_login() {
    local registry="$1"
    local registry_type=$(detect_registry_type "$registry")

    case "$registry_type" in
        acr)
            log_info "Detected Azure Container Registry"
            if command_exists az; then
                local acr_name=$(echo "$registry" | cut -d'.' -f1)
                log_info "Attempting ACR login for: $acr_name"
                az acr login --name "$acr_name" 2>/dev/null
            else
                log_warning "Azure CLI not found, assuming already logged in"
            fi
            ;;
        gcr)
            log_info "Detected Google Container Registry"
            if command_exists gcloud; then
                log_info "Configuring Docker for GCR"
                gcloud auth configure-docker 2>/dev/null
            else
                log_warning "gcloud CLI not found, assuming already configured"
            fi
            ;;
        ecr)
            log_info "Detected Amazon ECR"
            if command_exists aws; then
                log_info "Getting ECR login token"
                local region=$(echo "$registry" | cut -d'.' -f4)
                aws ecr get-login-password --region "$region" | \
                    docker login --username AWS --password-stdin "$registry" 2>/dev/null
            else
                log_warning "AWS CLI not found, assuming already logged in"
            fi
            ;;
        dockerhub)
            log_info "Using Docker Hub"
            if [ -n "$DOCKER_USERNAME" ] && [ -n "$DOCKER_PASSWORD" ]; then
                echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin 2>/dev/null
            else
                log_debug "Docker Hub credentials not set, assuming already logged in"
            fi
            ;;
        *)
            log_debug "Generic registry, assuming authentication is configured"
            ;;
    esac

    return 0
}

# Tag image with multiple tags
tag_image() {
    local source_image="$1"
    local target_image="$2"

    check_docker || return 1

    if [ -z "$source_image" ] || [ -z "$target_image" ]; then
        log_error "Source and target images are required"
        return 1
    fi

    if ! docker image inspect "$source_image" >/dev/null 2>&1; then
        log_error "Source image not found: $source_image"
        return 1
    fi

    log_info "Tagging $source_image as $target_image"
    if docker tag "$source_image" "$target_image"; then
        log_info "Image tagged successfully"
        return 0
    else
        log_error "Failed to tag image"
        return 1
    fi
}

# Get image information
get_image_info() {
    local image="${1:-$(get_full_image)}"

    check_docker || return 1

    if ! docker image inspect "$image" >/dev/null 2>&1; then
        log_error "Image not found: $image"
        return 1
    fi

    echo "Image: $image"
    echo "ID: $(docker image inspect "$image" --format '{{.Id}}' | cut -d: -f2 | head -c 12)"
    echo "Created: $(docker image inspect "$image" --format '{{.Created}}')"
    echo "Size: $(docker image inspect "$image" --format '{{.Size}}' | numfmt --to=iec-i --suffix=B)"
    echo "Architecture: $(docker image inspect "$image" --format '{{.Architecture}}')"
    echo "OS: $(docker image inspect "$image" --format '{{.Os}}')"

    local labels=$(docker image inspect "$image" --format '{{range $k, $v := .Config.Labels}}{{$k}}={{$v}}{{println}}{{end}}')
    if [ -n "$labels" ]; then
        echo "Labels:"
        echo "$labels" | sed 's/^/  /'
    fi
}

# Clean up old images
cleanup_images() {
    local image_name="${IMAGE_NAME:-$DEFAULT_IMAGE_NAME}"
    local keep_last="${1:-3}"

    check_docker || return 1

    log_info "Cleaning up old images (keeping last $keep_last)"

    # Get all images with the name, sorted by creation time
    local images=$(docker images "$image_name" --format "{{.Repository}}:{{.Tag}}" | grep -v '<none>')
    local count=$(echo "$images" | wc -l)

    if [ "$count" -le "$keep_last" ]; then
        log_info "No cleanup needed ($count images found)"
        return 0
    fi

    local to_remove=$((count - keep_last))
    log_info "Removing $to_remove old images"

    echo "$images" | tail -n "$to_remove" | while read -r image; do
        log_info "Removing: $image"
        docker rmi "$image" 2>/dev/null || log_warning "Failed to remove $image (might be in use)"
    done

    # Clean up dangling images
    local dangling=$(docker images -f "dangling=true" -q)
    if [ -n "$dangling" ]; then
        log_info "Removing dangling images"
        echo "$dangling" | xargs docker rmi 2>/dev/null || true
    fi

    log_info "Cleanup complete"
}

# Scan image for vulnerabilities (if scanner available)
scan_image() {
    local image="${1:-$(get_full_image)}"

    check_docker || return 1

    if ! docker image inspect "$image" >/dev/null 2>&1; then
        log_error "Image not found: $image"
        return 1
    fi

    # Try trivy if available
    if command_exists trivy; then
        log_info "Scanning image with Trivy: $image"
        trivy image --severity HIGH,CRITICAL "$image"
        return $?
    fi

    # Try docker scan if available
    if docker scan --version >/dev/null 2>&1; then
        log_info "Scanning image with Docker Scan: $image"
        docker scan "$image"
        return $?
    fi

    log_warning "No vulnerability scanner found"
    log_info "Consider installing Trivy: https://github.com/aquasecurity/trivy"
    return 2
}

# Export image to tar file
export_image() {
    local image="${1:-$(get_full_image)}"
    local output="${2:-${image//\//_}.tar}"

    check_docker || return 1

    if ! docker image inspect "$image" >/dev/null 2>&1; then
        log_error "Image not found: $image"
        return 1
    fi

    log_info "Exporting image to: $output"
    if docker save "$image" -o "$output"; then
        log_info "Image exported successfully ($(du -h "$output" | cut -f1))"
        echo "$output"
        return 0
    else
        log_error "Failed to export image"
        return 1
    fi
}

# Import image from tar file
import_image() {
    local input="$1"

    check_docker || return 1

    if [ ! -f "$input" ]; then
        log_error "File not found: $input"
        return 1
    fi

    log_info "Importing image from: $input"
    if docker load -i "$input"; then
        log_info "Image imported successfully"
        return 0
    else
        log_error "Failed to import image"
        return 1
    fi
}