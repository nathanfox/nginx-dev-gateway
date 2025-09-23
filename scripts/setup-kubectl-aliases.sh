#!/bin/bash

# Setup script for kubectl aliases and functions
# This script adds useful kubectl shortcuts to ~/.bash_aliases

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}Setting up kubectl aliases and helper functions...${NC}"

# Remove any existing kubectl completion from bashrc (to avoid messy output)
echo -e "${YELLOW}Removing kubectl tab completion if present...${NC}"
sed -i '/kubectl completion bash/d' ~/.bashrc 2>/dev/null || true
sed -i '/complete.*kubectl/d' ~/.bashrc 2>/dev/null || true
sed -i '/__start_kubectl/d' ~/.bashrc 2>/dev/null || true
sed -i '/source <(kubectl completion bash)/d' ~/.bashrc 2>/dev/null || true

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo -e "${YELLOW}Warning: kubectl is not installed. Install it first using:${NC}"
    echo "  sudo apt-get update && sudo apt-get install -y kubectl"
    echo "  Or see docs/kubectl-setup.md for other installation methods"
    exit 1
fi

# Backup existing .bash_aliases if it exists
if [ -f ~/.bash_aliases ]; then
    echo -e "${YELLOW}Backing up existing ~/.bash_aliases to ~/.bash_aliases.backup${NC}"
    cp ~/.bash_aliases ~/.bash_aliases.backup
fi

# Create .bash_aliases if it doesn't exist
touch ~/.bash_aliases

# Check if aliases are already installed
if grep -q "# Kubectl Aliases" ~/.bash_aliases; then
    echo -e "${YELLOW}Kubectl aliases already exist in ~/.bash_aliases${NC}"
    read -p "Do you want to reinstall/update them? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Skipping alias installation"
        exit 0
    fi
    # Remove existing kubectl aliases section
    echo "Removing existing kubectl aliases..."
    sed -i '/# ============================================/,/# End of kubectl aliases/d' ~/.bash_aliases 2>/dev/null || true
    sed -i '/# Kubectl Aliases/,/^$/d' ~/.bash_aliases 2>/dev/null || true
fi

# Add kubectl aliases to ~/.bash_aliases
cat >> ~/.bash_aliases << 'EOF'

# ============================================
# Kubectl Aliases
# ============================================

# Core kubectl alias
alias k='kubectl'

# Getting resources
alias kgp='kubectl get pods'
alias kgpa='kubectl get pods --all-namespaces'
alias kgpw='kubectl get pods -o wide'
alias kgs='kubectl get svc'
alias kgn='kubectl get nodes'
alias kgd='kubectl get deployment'
alias kgns='kubectl get namespaces'
alias kgi='kubectl get ingress'
alias kgcm='kubectl get configmap'
alias kgsec='kubectl get secret'
alias kgpv='kubectl get pv'
alias kgpvc='kubectl get pvc'

# Describing resources
alias kd='kubectl describe'
alias kdp='kubectl describe pod'
alias kds='kubectl describe svc'
alias kdd='kubectl describe deployment'
alias kdn='kubectl describe node'

# Logs
alias kl='kubectl logs'
alias klf='kubectl logs -f'
alias klp='kubectl logs -p'  # Previous container logs

# Executing commands
alias ke='kubectl exec -it'

# Applying/Deleting resources
alias kaf='kubectl apply -f'
alias kdf='kubectl delete -f'
alias kdel='kubectl delete'

# Editing resources
alias ked='kubectl edit deployment'
alias kecm='kubectl edit configmap'
alias kes='kubectl edit service'

# Namespace operations
alias kns='kubectl config set-context --current --namespace'
alias kgc='kubectl config get-contexts'
alias kuc='kubectl config use-context'

# ============================================
# Helper Functions
# ============================================

# Switch or show namespace
kn() {
    if [ -z "$1" ]; then
        kubectl config view --minify | grep namespace | sed 's/.*namespace: //'
    else
        kubectl config set-context --current --namespace="$1"
        echo "Switched to namespace: $1"
    fi
}

# Get all resources in a namespace
kga() {
    if [ -z "$1" ]; then
        kubectl get all
    else
        kubectl get all -n "$1"
    fi
}

# Watch pods in current namespace
kwp() {
    watch -n 1 "kubectl get pods ${1:+-n $1}"
}

# Get pod logs by partial name
klg() {
    if [ -z "$1" ]; then
        echo "Usage: klg <partial-pod-name>"
        return 1
    fi
    pod=$(kubectl get pods --no-headers -o custom-columns=":metadata.name" | grep "$1" | head -1)
    if [ -n "$pod" ]; then
        kubectl logs -f "$pod"
    else
        echo "No pod found matching: $1"
    fi
}

# Exec into pod by partial name
kex() {
    if [ -z "$1" ]; then
        echo "Usage: kex <partial-pod-name> [command]"
        return 1
    fi
    pod=$(kubectl get pods --no-headers -o custom-columns=":metadata.name" | grep "$1" | head -1)
    if [ -n "$pod" ]; then
        kubectl exec -it "$pod" -- ${2:-/bin/bash}
    else
        echo "No pod found matching: $1"
    fi
}

# Port forward by service name
kpf() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "Usage: kpf <service-name> <local-port:remote-port>"
        echo "Example: kpf nginx-gateway 8080:80"
        return 1
    fi
    kubectl port-forward "svc/$1" "$2"
}

# Get events sorted by timestamp
kev() {
    kubectl get events --sort-by='.lastTimestamp' ${1:+-n $1}
}

# Show resource usage
ktop() {
    kubectl top nodes
    echo "---"
    kubectl top pods ${1:+-n $1}
}

# Quick deployment restart
krestart() {
    if [ -z "$1" ]; then
        echo "Usage: krestart <deployment-name>"
        return 1
    fi
    kubectl rollout restart deployment "$1"
}

# Get pod by label
kgpl() {
    if [ -z "$1" ]; then
        echo "Usage: kgpl <label-selector>"
        echo "Example: kgpl app=nginx"
        return 1
    fi
    kubectl get pods -l "$1"
}

# Decode a secret
kdecode() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "Usage: kdecode <secret-name> <key>"
        return 1
    fi
    kubectl get secret "$1" -o jsonpath="{.data.$2}" | base64 -d
    echo ""
}

# Quick resource type shortcuts
kg() {
    case "$1" in
        p|po|pod|pods)
            kubectl get pods ${@:2}
            ;;
        s|svc|service|services)
            kubectl get services ${@:2}
            ;;
        d|dep|deploy|deployment|deployments)
            kubectl get deployments ${@:2}
            ;;
        n|ns|namespace|namespaces)
            kubectl get namespaces ${@:2}
            ;;
        cm|configmap|configmaps)
            kubectl get configmaps ${@:2}
            ;;
        secret|secrets)
            kubectl get secrets ${@:2}
            ;;
        ing|ingress|ingresses)
            kubectl get ingresses ${@:2}
            ;;
        node|nodes)
            kubectl get nodes ${@:2}
            ;;
        all)
            kubectl get all ${@:2}
            ;;
        *)
            echo "Usage: kg <resource-type> [options]"
            echo "Resource types:"
            echo "  p|po|pod|pods           - List pods"
            echo "  s|svc|service|services  - List services"
            echo "  d|dep|deploy|deployment - List deployments"
            echo "  n|ns|namespace          - List namespaces"
            echo "  cm|configmap            - List configmaps"
            echo "  secret|secrets          - List secrets"
            echo "  ing|ingress             - List ingresses"
            echo "  node|nodes              - List nodes"
            echo "  all                     - List all resources"
            echo ""
            echo "Examples:"
            echo "  kg p                    - List pods in current namespace"
            echo "  kg p -A                 - List pods in all namespaces"
            echo "  kg p -n kube-system     - List pods in kube-system namespace"
            ;;
    esac
}

# End of kubectl aliases
EOF

echo -e "${GREEN}✓ Kubectl aliases added to ~/.bash_aliases${NC}"

# Check if .bashrc sources .bash_aliases
if ! grep -q "\.bash_aliases" ~/.bashrc; then
    echo -e "${YELLOW}Adding source command to ~/.bashrc${NC}"
    cat >> ~/.bashrc << 'EOF'

# Alias definitions
if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi
EOF
fi

# No kubectl completion setup (avoiding messy tab completion output)

echo -e "${GREEN}✓ Setup complete!${NC}"
echo
echo "To activate the aliases, run:"
echo -e "  ${GREEN}source ~/.bashrc${NC}"
echo
echo "Or start a new terminal session."
echo
echo "Quick reference:"
echo "  ${GREEN}kgp${NC}          - kubectl get pods"
echo "  ${GREEN}kgs${NC}          - kubectl get services"
echo "  ${GREEN}kgd${NC}          - kubectl get deployments"
echo "  ${GREEN}kn <ns>${NC}      - switch namespace"
echo "  ${GREEN}kex <pod>${NC}    - exec into pod by partial name"
echo "  ${GREEN}klg <pod>${NC}    - get logs by partial name"
echo "  ${GREEN}kpf <svc> <port>${NC} - port-forward a service"
echo
echo "Or use the kg shortcut:"
echo "  ${GREEN}kg p${NC}         - get pods"
echo "  ${GREEN}kg s${NC}         - get services"
echo "  ${GREEN}kg d${NC}         - get deployments"
echo
echo "For full list of aliases, type: ${GREEN}alias | grep kubectl${NC}"