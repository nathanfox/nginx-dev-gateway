# kubectl Setup Guide for Ubuntu

This guide covers installing and configuring kubectl on Ubuntu with useful aliases and auto-completion for efficient Kubernetes management.

## Table of Contents

1. [Installation](#installation)
2. [Auto-completion Setup](#auto-completion-setup)
3. [Useful Aliases](#useful-aliases)
4. [AKS Integration](#aks-integration)
5. [Quick Reference](#quick-reference)

## Installation

### Method 1: Official apt Repository (Recommended)

This method ensures you get updates automatically:

```bash
# Update apt and install required packages
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

# Add Google Cloud public signing key
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Add Kubernetes apt repository
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Update apt and install kubectl
sudo apt-get update
sudo apt-get install -y kubectl

# Verify installation
kubectl version --client
```

### Method 2: Direct Binary Download

Quick installation without package management:

```bash
# Download latest stable kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

# Make it executable
chmod +x kubectl

# Move to PATH
sudo mv kubectl /usr/local/bin/

# Verify installation
kubectl version --client
```

### Method 3: Using Snap

Simple but may lag behind latest version:

```bash
# Install via snap
sudo snap install kubectl --classic

# Verify installation
kubectl version --client
```

### Method 4: Azure CLI (For AKS Users)

If you're using Azure Kubernetes Service:

```bash
# Install kubectl and kubelogin through Azure CLI
sudo az aks install-cli
```

## Note on Tab Completion

This guide does not set up kubectl tab completion due to formatting issues that can occur in some terminal environments. Instead, we provide comprehensive aliases and helper functions that are faster to use than tab completion.

## Useful Aliases

Ubuntu uses `~/.bash_aliases` for organizing command aliases.

### Quick Setup (Recommended)

Use the provided setup script which will:
- Add kubectl aliases and helper functions
- Remove any existing tab completion (to avoid formatting issues)
- Configure your shell for optimal kubectl usage

```bash
# Run the setup script from the nginx-dev-gateway project
./scripts/setup-kubectl-aliases.sh

# Activate the aliases
source ~/.bashrc
```

### Manual Setup

If you prefer to add aliases manually:

```bash
# Create .bash_aliases if it doesn't exist
touch ~/.bash_aliases

# Add kubectl aliases
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
            echo "Examples: kg p, kg s, kg d"
            ;;
    esac
}

EOF
```

## Ensure .bash_aliases is Sourced

Ubuntu should source `.bash_aliases` by default, but verify:

```bash
# Check if .bashrc sources .bash_aliases
grep -q "\.bash_aliases" ~/.bashrc || cat >> ~/.bashrc << 'EOF'

# Alias definitions
if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi
EOF

# Reload configuration
source ~/.bashrc
```

## AKS Integration

### Connect to AKS Cluster

```bash
# Login to Azure
az login

# Get AKS credentials (standard method)
az aks get-credentials --resource-group <resource-group> --name <cluster-name>

# Verify connection
kubectl get nodes

# List available contexts
kubectl config get-contexts

# Switch between clusters
kubectl config use-context <context-name>
```

### Authentication Methods

AKS supports two authentication methods:

#### 1. **Local Accounts (Default)**
Most AKS clusters use local accounts by default, which work immediately after `az aks get-credentials`:

```bash
# Check if local accounts are enabled (default)
az aks show -g <resource-group> -n <cluster-name> --query "disableLocalAccounts"
# Returns "false" or null = local accounts enabled (no kubelogin needed)

# For admin access (bypasses AAD if enabled)
az aks get-credentials -g <resource-group> -n <cluster-name> --admin
```

#### 2. **Azure AD Authentication (Optional)**
Only required if your organization enforces AAD authentication:

```bash
# Check your current auth method
kubectl config view --minify --raw | grep -E "client-certificate|exec"
# "client-certificate-data" = local accounts (no kubelogin needed)
# "exec" with "kubelogin" = AAD auth (kubelogin required)
```

### Install kubelogin (Only if Required)

**You only need kubelogin if:**
- Your AKS cluster has AAD integration enabled
- Local accounts are disabled
- You get an error: "You must be logged in to the server (the server has asked for the client to provide credentials)"

If needed, install kubelogin:

```bash
# Install via Azure CLI (recommended)
sudo az aks install-cli

# Or install directly
wget https://github.com/Azure/kubelogin/releases/latest/download/kubelogin-linux-amd64.zip
unzip kubelogin-linux-amd64.zip
sudo mv bin/linux_amd64/kubelogin /usr/local/bin/
rm -rf kubelogin-linux-amd64.zip bin/

# Verify installation
kubelogin --version
```

**Note:** Most development AKS clusters work fine without kubelogin. It's primarily needed in enterprise environments with strict AAD authentication requirements.

## Quick Reference

### Most Common Commands with Aliases

| Alias | Full Command | Description |
|-------|--------------|-------------|
| `k` | `kubectl` | Base kubectl command |
| `kgp` | `kubectl get pods` | List pods in current namespace |
| `kgpa` | `kubectl get pods --all-namespaces` | List all pods in cluster |
| `kgs` | `kubectl get services` | List services |
| `kgd` | `kubectl get deployments` | List deployments |
| `kl <pod>` | `kubectl logs <pod>` | View pod logs |
| `klf <pod>` | `kubectl logs -f <pod>` | Follow pod logs |
| `ke <pod> bash` | `kubectl exec -it <pod> -- bash` | Shell into pod |
| `kn <namespace>` | Switch namespace | Change current namespace |
| `kn` | Show current namespace | Display current namespace |
| `kga` | `kubectl get all` | Get all resources |
| `kaf <file>` | `kubectl apply -f <file>` | Apply configuration |
| `kdp <pod>` | `kubectl describe pod <pod>` | Describe pod details |
| `kg <type>` | Quick get resources | `kg p` for pods, `kg s` for services, etc |

### Common Workflows

```bash
# Switch to a namespace and view pods
kn developer-john
kgp

# Use kg for quick resource access
kg p                    # Get pods
kg s                    # Get services
kg d                    # Get deployments
kg p -n kube-system    # Get pods in specific namespace

# Follow logs of a pod (partial name match)
klg nginx

# Execute into a pod (partial name match)
kex nginx bash

# Port forward a service
kpf nginx-gateway 8080:80

# Watch pods updating
kwp

# Restart a deployment
krestart nginx-gateway

# Check resource usage
ktop

# View recent events
kev
```

### Troubleshooting

```bash
# Get events in current namespace
kev

# Get events in specific namespace
kev developer-john

# Describe a problematic pod
kdp <pod-name>

# Get previous container logs (after crash)
klp <pod-name>

# Check node status
kgn
kdn <node-name>

# View resource usage
ktop
```

## Tips

1. **Use `k` instead of `kubectl`** - It's much faster to type
2. **Use functions for complex operations** - `kex nginx` is easier than finding the full pod name
3. **Set a default namespace** - Use `kn <namespace>` to avoid typing `-n` repeatedly
4. **Tab completion works with aliases** - Try `k get p<TAB>`
5. **Chain commands** - `kn dev && kgp` to switch namespace and list pods

## File Organization

- **`~/.bashrc`**: Sources other files, sets up completions
- **`~/.bash_aliases`**: Contains all aliases and functions
- **`~/.kube/config`**: Kubernetes cluster configurations

## Next Steps

1. Install kubectl using Method 1 (recommended)
2. Set up auto-completion
3. Add aliases to `~/.bash_aliases`
4. Connect to your cluster
5. Try the aliases and functions

Remember to `source ~/.bashrc` after making changes or open a new terminal session.