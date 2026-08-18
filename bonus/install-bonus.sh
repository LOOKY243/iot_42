#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/k8s"
CLUSTER_CONFIG="${SCRIPT_DIR}/cluster.yml"
APPLICATION_MANIFEST="${K8S_DIR}/application.yml"
GITLAB_PORT="8929"

if [[ ! -f "$CLUSTER_CONFIG" ]]; then
    echo "Cluster config not found: $CLUSTER_CONFIG"
    exit 1
fi

if ! k3d cluster list 2>/dev/null | grep -q "iot-bonus-cluster"; then
    echo "Creating the k3d bonus cluster..."
    rm -f "${SCRIPT_DIR}/.gitlab_root_password"
    k3d cluster create --config "$CLUSTER_CONFIG"
else
    echo "-> The k3d bonus cluster already exists."
fi

echo "Waiting for the cluster..."
until kubectl cluster-info &> /dev/null; do
    sleep 2
done

echo "Installing GitLab (single lightweight pod, no Helm chart)..."
kubectl apply -f "${K8S_DIR}/gitlab/namespace.yml"
kubectl apply -f "${K8S_DIR}/gitlab/pvc.yml"

ROOT_PASS_FILE="${SCRIPT_DIR}/.gitlab_root_password"
if [[ -f "$ROOT_PASS_FILE" ]]; then
    ROOT_PASS="$(cat "$ROOT_PASS_FILE")"
else
    ROOT_PASS=$(openssl rand -hex 16)
    echo "$ROOT_PASS" > "$ROOT_PASS_FILE"
fi

GITLAB_DEPLOYMENT="$(mktemp)"
sed "s/__GITLAB_ROOT_PASSWORD__/${ROOT_PASS}/" "${K8S_DIR}/gitlab/deployment.yml" > "$GITLAB_DEPLOYMENT"
kubectl apply -f "$GITLAB_DEPLOYMENT"
rm -f "$GITLAB_DEPLOYMENT"

kubectl apply -f "${K8S_DIR}/gitlab/service.yml"
kubectl apply -f "${K8S_DIR}/gitlab/ingress.yml"

echo "Waiting for the GitLab pod to be scheduled..."
kubectl -n gitlab wait --for=condition=PodScheduled pod -l app=gitlab --timeout=120s

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -

if ! kubectl get deployment argocd-server -n argocd &> /dev/null; then
    echo "Installation d'Argo CD..."
    kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
else
    echo "-> Argo CD is already installed."
fi

kubectl -n argocd wait --for=condition=available --timeout=600s deployment/argocd-server

echo "Waiting for GitLab to finish its first-boot reconfigure (this can take several minutes)..."
kubectl -n gitlab port-forward svc/gitlab-service "$GITLAB_PORT":80 > /dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2> /dev/null || true' EXIT

for i in $(seq 1 90); do
    if [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$GITLAB_PORT/-/health")" == "200" ]]; then
        break
    fi
    if [[ $i -eq 90 ]]; then
        echo "GitLab did not become healthy in time."
        kubectl -n gitlab get pods
        exit 1
    fi
    kill -0 "$PF_PID" 2>/dev/null || {
        kubectl -n gitlab port-forward svc/gitlab-service "$GITLAB_PORT":80 > /dev/null 2>&1 &
        PF_PID=$!
    }
    sleep 10
done
kill "$PF_PID" 2> /dev/null || true
trap - EXIT

cat <<EOF
  Username: root
  Password: $ROOT_PASS
EOF
