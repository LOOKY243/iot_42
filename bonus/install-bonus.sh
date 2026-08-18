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

# GitLab is pre-provisioned with a known root password via GITLAB_ROOT_PASSWORD
# so the defense doesn't depend on scraping a generated secret. Minting an API
# token automatically (OAuth password grant, gitlab-rails runner) turned out to
# either be rejected by GitLab itself or heavy enough to compete with GitLab's
# own Puma/Sidekiq for memory inside the same pod on a constrained host - so
# that step is done once, by hand, from the printed instructions below. It also
# matches what the correction sheet actually checks: the evaluator watches the
# group create a repo and push to it live, not a script doing it beforehand.
ROOT_PASS=$(openssl rand -hex 16)

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
    # port-forward can drop under load; restart it if it did
    kill -0 "$PF_PID" 2>/dev/null || {
        kubectl -n gitlab port-forward svc/gitlab-service "$GITLAB_PORT":80 > /dev/null 2>&1 &
        PF_PID=$!
    }
    sleep 10
done
kill "$PF_PID" 2> /dev/null || true
trap - EXIT

cat <<EOF

Bonus infrastructure ready!

GitLab:
  URL:      http://gitlab.local (via the Ingress) or run:
              kubectl -n gitlab port-forward svc/gitlab-service $GITLAB_PORT:80
            then open http://localhost:$GITLAB_PORT
  Username: root
  Password: $ROOT_PASS

Remaining one-time setup (do this once, or live during the defense):
  1. Log in to GitLab as root with the password above.
  2. Create a new project named "iot-app" (visibility: public).
  3. In GitLab: Settings -> Access Tokens, create a token with the
     "api" and "write_repository" scopes.
  4. Push Part 3's manifests into it:
       mkdir -p /tmp/iot-app/k8s
       cp ${SCRIPT_DIR}/../p3/k8s/deployment.yml ${SCRIPT_DIR}/../p3/k8s/service.yml /tmp/iot-app/k8s/
       cd /tmp/iot-app
       git init -b main
       git add .
       git commit -m "app v1"
       git remote add origin http://root:<your-token>@localhost:$GITLAB_PORT/root/iot-app.git
       git push -u origin main
  5. Point Argo CD at it:
       kubectl apply -f ${APPLICATION_MANIFEST}
EOF
