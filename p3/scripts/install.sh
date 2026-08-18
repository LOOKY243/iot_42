#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
K3D_CONFIG="${PROJECT_ROOT}/config/k3d_config.yml"
ARGOCD_APP="${PROJECT_ROOT}/config/argo_cd_application.yml"
CLUSTER_NAME="iot-cluster"

if ! command -v docker &> /dev/null; then
    echo "Docker is not installed. Installing..."
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker "$USER"
    echo "Docker installed. Restart your shell session so the docker group is picked up."
fi

if ! docker info &> /dev/null; then
    echo "Docker is installed but not operational / not accessible for this user."
    if command -v systemctl &> /dev/null; then
        sudo systemctl enable --now docker
    fi

    if ! id -nG "$USER" | grep -qw docker; then
        echo "Current user is not in the docker group. Adding the user to the docker group..."
        sudo usermod -aG docker "$USER"
        echo "Added the user to the docker group. Please log out and log back in (or run 'newgrp docker') before rerunning this script."
        exit 1
    fi

    if ! docker info &> /dev/null; then
        echo "The Docker daemon is running, but Docker access is still unavailable. Log out and back in or run 'newgrp docker' and retry."
        exit 1
    fi
else
    echo "-> Docker is already installed and accessible."
fi

# Check and install k3d
if ! command -v k3d &> /dev/null; then
    echo "k3d is not installed. Installing..."
    curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | sudo bash
    echo "k3d installed."
else
    echo "-> k3d is already installed."
fi

# Check and install kubectl
if ! command -v kubectl &> /dev/null; then
    echo "kubectl is not installed. Installing..."
    STABLE_VERSION="$(curl -L -s https://dl.k8s.io/release/stable.txt)"
    curl -LO "https://dl.k8s.io/release/${STABLE_VERSION}/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
    echo "kubectl installed."
else
    echo "-> kubectl is already installed."
fi

if ! k3d cluster list 2>/dev/null | grep -q "$CLUSTER_NAME"; then
    if [[ ! -f "$K3D_CONFIG" ]]; then
        echo "k3d config file not found: $K3D_CONFIG"
        exit 1
    fi

    echo "Creating the k3d cluster..."
    k3d cluster create --config "$K3D_CONFIG"
else
    echo "-> The k3d cluster already exists."
fi

echo "Waiting for the cluster to be ready..."
for i in $(seq 1 60); do
    if kubectl cluster-info &> /dev/null; then
        break
    fi
    if [[ $i -eq 60 ]]; then
        echo "The cluster did not become reachable in time."
        k3d cluster list
        docker ps -a --filter name=k3d- --format '{{.Names}}	{{.Status}}'
        exit 1
    fi
    sleep 2
done

echo "Checking namespaces..."
for ns in argocd dev; do
    if ! kubectl get namespace "$ns" &> /dev/null; then
        kubectl create namespace "$ns"
        echo "Namespace '$ns' created."
    else
        echo "-> Namespace '$ns' already exists."
    fi
done

if ! kubectl get deployment argocd-server -n argocd &> /dev/null; then
    echo "Installing Argo CD..."
    kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
else
    echo "-> Argo CD is already installed."
fi

kubectl -n argocd wait --for=condition=available --timeout=600s deployment/argocd-server

if [[ ! -f "$ARGOCD_APP" ]]; then
    echo "Argo CD application manifest not found: $ARGOCD_APP"
    exit 1
fi

kubectl apply -f "$ARGOCD_APP"

echo "Infrastructure ready!"

echo -n "Argo CD admin password: "
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo ""

echo "Starting port-forward (Ctrl+C to stop)..."
kubectl port-forward svc/argocd-server -n argocd 8080:443
