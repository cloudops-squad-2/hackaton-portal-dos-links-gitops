#!/usr/bin/env bash
# Portal dos Links - GitOps bootstrap
#
# Automates the "Bootstrap (First-Time Setup)" section of the README:
#   0. pre-flight check (HPA sync-wave fix on origin/develop)
#   1. start minikube              (only with --minikube)
#   2. install metrics-server
#   3. install ArgoCD
#   4. install ingress-nginx       (ArgoCD Application, NodePort)
#   5. create namespaces
#   6. create secrets
#   7. deploy observability stack  (wave 0)
#   8. deploy the portal           (wave 1)
#   9. verify
#
# Usage:
#   ./bootstrap.sh [options]
#
# Options:
#   --minikube         Start a minikube cluster first (4 CPUs, 6 GiB) and
#                      apply the kubelet-insecure-tls patch to metrics-server
#   --insecure-tls     Apply the kubelet-insecure-tls patch (kind / minikube)
#   --skip-preflight   Skip the origin/develop HPA sync-wave check
#   --timeout SECONDS  Max wait per ArgoCD Application (default: 900)
#   -h, --help         Show this help
#
# Environment variables (optional):
#   POSTGRES_PASSWORD  Password for the database secrets. If unset and the
#                      secrets do not exist yet, a random one is generated.
#                      Ignored when k8s/*/secret.yaml files exist locally.
#   POSTGRES_USER      Default: portal
#   POSTGRES_DB        Default: portal

set -euo pipefail

START_MINIKUBE=false
INSECURE_TLS=false
SKIP_PREFLIGHT=false
APP_TIMEOUT=900

NS_PORTAL="portal-dos-links"
NS_OBS="observability"
NS_ARGO="argocd"

POSTGRES_USER="${POSTGRES_USER:-portal}"
POSTGRES_DB="${POSTGRES_DB:-portal}"

while [ $# -gt 0 ]; do
  case "$1" in
    --minikube)       START_MINIKUBE=true; INSECURE_TLS=true ;;
    --insecure-tls)   INSECURE_TLS=true ;;
    --skip-preflight) SKIP_PREFLIGHT=true ;;
    --timeout)        shift; APP_TIMEOUT="${1:?--timeout needs a value}" ;;
    -h|--help)        sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

log()  { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$1"; }
ok()   { printf '\033[1;32m✔\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31m✘\033[0m %s\n' "$1" >&2; exit 1; }

# Run from the repo root (where this script lives)
cd "$(dirname "$0")"

# Wait until an ArgoCD Application is Synced + Healthy
wait_app() {
  local name="$1" elapsed=0 sync health
  while [ "$elapsed" -lt "$APP_TIMEOUT" ]; do
    sync=$(kubectl get application "$name" -n "$NS_ARGO" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
    health=$(kubectl get application "$name" -n "$NS_ARGO" -o jsonpath='{.status.health.status}' 2>/dev/null || true)
    printf '\r   %-28s sync=%-10s health=%-12s (%ss)   ' "$name" "${sync:-?}" "${health:-?}" "$elapsed"
    if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
      printf '\n'; ok "$name is Synced + Healthy"; return 0
    fi
    sleep 10; elapsed=$((elapsed + 10))
  done
  printf '\n'
  warn "Timed out waiting for $name. Inspect with:"
  echo "   kubectl describe application $name -n $NS_ARGO"
  return 1
}

# Percent-encode a string for use inside DATABASE_URL
urlencode() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
  elif [[ "$1" =~ ^[A-Za-z0-9._~-]+$ ]]; then
    printf '%s' "$1"
  else
    fail "Password has special characters and python3 is not available to URL-encode it."
  fi
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
log "Checking prerequisites"
command -v kubectl >/dev/null 2>&1 || fail "kubectl is not installed."
ok "kubectl found"
if $START_MINIKUBE; then
  command -v minikube >/dev/null 2>&1 || fail "minikube is not installed (needed for --minikube)."
  ok "minikube found"
fi

# ---------------------------------------------------------------------------
# Step 0 - Pre-flight
# ---------------------------------------------------------------------------
log "Step 0: Pre-flight check"
if $SKIP_PREFLIGHT; then
  warn "Skipped (--skip-preflight)"
elif git rev-parse --is-inside-work-tree >/dev/null 2>&1 && git remote get-url origin >/dev/null 2>&1; then
  git fetch origin --quiet
  if git show origin/develop:k8s/api/hpa.yaml 2>/dev/null | grep -q 'argocd.argoproj.io/sync-wave: "3"'; then
    ok "HPA sync-wave \"3\" fix is on origin/develop"
  else
    fail "k8s/api/hpa.yaml on origin/develop has no sync-wave \"3\". Merge the fix into develop first (or use --skip-preflight)."
  fi
else
  warn "Not a git checkout with an 'origin' remote, skipping the check"
fi

# ---------------------------------------------------------------------------
# Step 1 - Cluster (optional)
# ---------------------------------------------------------------------------
if $START_MINIKUBE; then
  log "Step 1: Starting minikube"
  if minikube status >/dev/null 2>&1; then
    ok "minikube already running"
  else
    minikube start --driver=docker --cpus=4 --memory=6144
  fi
  # The ingress addon would conflict with the ArgoCD-managed ingress-nginx
  warn "Do NOT enable the minikube ingress addon (ArgoCD manages ingress-nginx)"
else
  log "Step 1: Cluster"
  warn "Using the current kubectl context: $(kubectl config current-context 2>/dev/null || echo 'none')"
fi
kubectl get nodes >/dev/null 2>&1 || fail "Cannot reach the cluster. Check your kubeconfig."
ok "Cluster reachable"

# ---------------------------------------------------------------------------
# Step 2 - metrics-server
# ---------------------------------------------------------------------------
log "Step 2: Installing metrics-server"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
if $INSECURE_TLS; then
  if kubectl get deploy metrics-server -n kube-system \
       -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q 'kubelet-insecure-tls'; then
    ok "kubelet-insecure-tls already set"
  else
    kubectl patch deploy metrics-server -n kube-system --type=json \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
    ok "Applied kubelet-insecure-tls patch"
  fi
fi

# ---------------------------------------------------------------------------
# Step 3 - ArgoCD
# ---------------------------------------------------------------------------
log "Step 3: Installing ArgoCD"
kubectl create namespace "$NS_ARGO" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "$NS_ARGO" --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=Ready pods --all -n "$NS_ARGO" --timeout=300s
ok "ArgoCD is ready"

# ---------------------------------------------------------------------------
# Step 4 - ingress-nginx (managed by ArgoCD)
# ---------------------------------------------------------------------------
log "Step 4: Installing ingress-nginx"
kubectl apply -f argocd/ingress-nginx-app.yaml
wait_app ingress-nginx
svc_type=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.type}')
if [ "$svc_type" = "NodePort" ]; then
  ok "ingress-nginx-controller is NodePort"
else
  warn "ingress-nginx-controller is $svc_type (expected NodePort). Ingresses may never get an ADDRESS."
fi

# ---------------------------------------------------------------------------
# Step 5 - Namespaces
# ---------------------------------------------------------------------------
log "Step 5: Creating namespaces"
for ns in "$NS_PORTAL" "$NS_OBS"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# ---------------------------------------------------------------------------
# Step 6 - Secrets
# ---------------------------------------------------------------------------
log "Step 6: Creating secrets"
if [ -f k8s/database/secret.yaml ] && [ -f k8s/api/secret.yaml ]; then
  kubectl apply -f k8s/database/secret.yaml
  kubectl apply -f k8s/api/secret.yaml
  ok "Applied local secret.yaml files"
elif kubectl get secret postgres-secret api-secret -n "$NS_PORTAL" >/dev/null 2>&1; then
  ok "Secrets already exist in the cluster, leaving them untouched"
else
  if [ -z "${POSTGRES_PASSWORD:-}" ]; then
    POSTGRES_PASSWORD=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    warn "No POSTGRES_PASSWORD given, generated a random one (stored only in the cluster secrets)"
  fi
  encoded_pw=$(urlencode "$POSTGRES_PASSWORD")

  kubectl create secret generic postgres-secret -n "$NS_PORTAL" \
    --from-literal=POSTGRES_USER="$POSTGRES_USER" \
    --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
    --from-literal=POSTGRES_DB="$POSTGRES_DB"

  kubectl create secret generic api-secret -n "$NS_PORTAL" \
    --from-literal=DATABASE_URL="postgres://${POSTGRES_USER}:${encoded_pw}@postgres-svc:5432/${POSTGRES_DB}"
  ok "Created postgres-secret and api-secret"
fi

# ---------------------------------------------------------------------------
# Step 7 - Observability (wave 0)
# ---------------------------------------------------------------------------
log "Step 7: Deploying the observability stack"
kubectl apply -f argocd/observability/kube-prometheus-stack-app.yaml
kubectl apply -f argocd/observability/tempo-app.yaml
wait_app kube-prometheus-stack
wait_app tempo

# ---------------------------------------------------------------------------
# Step 8 - Portal (wave 1)
# ---------------------------------------------------------------------------
log "Step 8: Deploying the portal"
kubectl apply -f argocd/application.yaml
wait_app portal-dos-links

# ---------------------------------------------------------------------------
# Step 9 - Verify
# ---------------------------------------------------------------------------
log "Step 9: Verifying"
kubectl get pods -n "$NS_PORTAL"
kubectl get pods -n "$NS_OBS"
kubectl get ingress -n "$NS_PORTAL"
kubectl get hpa -n "$NS_PORTAL"

cat <<EOF

Done. Access the cluster with these port-forwards (one terminal each):

  Portal:      kubectl port-forward svc/ingress-nginx-controller -n ingress-nginx 8081:80
  ArgoCD:      kubectl port-forward svc/argocd-server -n argocd 8080:443
  Grafana:     kubectl port-forward svc/kube-prometheus-stack-grafana -n observability 8082:80
  Prometheus:  kubectl port-forward svc/kube-prometheus-stack-prometheus -n observability 8083:9090
  Tempo:       kubectl port-forward svc/tempo -n observability 8084:3200

ArgoCD admin password:
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo

Smoke test (with the portal port-forward running):
  curl -i -X POST http://localhost:8081/api/links -H 'Content-Type: application/json' -d '{"url":"https://example.com"}'
EOF
