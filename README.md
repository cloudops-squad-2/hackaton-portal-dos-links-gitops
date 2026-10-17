# Portal dos Links — GitOps Config Repo

> "A stack todo mundo tem. O portal é só seu."

This repository is the **source of truth** for the Kubernetes cluster that runs the Portal dos Links — a creative cloud-native link shortener built for the CloudOps Bootcamp Hackathon.

ArgoCD watches this repo and automatically reconciles the cluster state with whatever is on the `develop` branch. You do not `kubectl apply` app manifests manually — you push to Git and let ArgoCD do the work.

---

## The Application

| Component | Image | Port | Description |
|---|---|---|---|
| **API** | `ghcr.io/cloudops-squad-2/portal-dos-links-api` | 3000 | NestJS — shortens links, handles redirects |
| **Frontend** | `ghcr.io/cloudops-squad-2/portal-dos-links-frontend` | 80 | nginx serving Vite static build |
| **Database** | `postgres:16-alpine` | 5432 | PostgreSQL — maps short codes → URLs |

---

## Repo Structure

```
.
├── argocd/
│   └── application.yaml          # ArgoCD Application CRD — registers this repo with ArgoCD
├── k8s/
│   ├── kustomization.yaml        # Root — namespace, resources, image tag overrides
│   ├── api/
│   │   ├── configmap.yaml        # Non-sensitive config (OTEL endpoint only)
│   │   ├── secret.yaml           # DATABASE_URL — gitignored, apply manually
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── kustomization.yaml
│   ├── frontend/
│   │   ├── deployment.yaml       # No ConfigMap — Vite bakes env vars at build time
│   │   ├── service.yaml
│   │   ├── ingress-api.yaml      # /api and /s paths → API (with nginx rewrite)
│   │   ├── ingress-frontend.yaml # / path → Frontend (no rewrite)
│   │   └── kustomization.yaml
│   ├── database/
│   │   ├── secret.yaml           # Postgres credentials — gitignored, apply manually
│   │   ├── pvc.yaml              # 1Gi persistent volume
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── kustomization.yaml
│   └── observability/            # OTEL Collector + Grafana dashboards + alerts
├── .github/
│   └── workflows/
│       └── ci.yaml               # Gitleaks + kustomize build + kubeconform validation
├── .gitignore
└── README.md
```

---

## Prerequisites

Make sure you have these tools installed:

- [`kubectl`](https://kubernetes.io/docs/tasks/tools/) — Kubernetes CLI
- [`kustomize`](https://kubectl.docs.kubernetes.io/installation/kustomize/) >= 5.4.3
- [`helm`](https://helm.sh/docs/intro/install/) >= 3.14 — required for observability stack deployment
- [`argocd` CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/) (optional, for managing ArgoCD from terminal)
- Access to a Kubernetes cluster (kind, minikube, or remote)
- Access to the GitHub Container Registry (`ghcr.io/cloudops-squad-2/`)
- **`metrics-server`** installed in the cluster — required for HPA (Horizontal Pod Autoscaler) to function. Most managed clusters include it by default. For kind/minikube see [metrics-server docs](https://github.com/kubernetes-sigs/metrics-server).

---

## Bootstrap (first time setup)

**Required bootstrap order** — components must come up in this sequence to avoid dependency failures:

1. **ingress-nginx** — Ingress controller (all Ingress resources depend on it)
2. **metrics-server** — required for HPA to function
3. **ArgoCD** — sync controller
4. **Namespace** — create manually so secrets can be applied before first sync
5. **Secrets** — apply manually (gitignored, never committed)
6. **Observability stack** (sync-wave 0) — kube-prometheus-stack + Tempo; must be running before the portal app so CRDs exist
7. **Portal Application** (sync-wave 1) — ArgoCD syncs after observability CRDs are ready

> **Note:** Prometheus, Grafana, and Tempo are **never exposed via public Ingress**. Access them via `kubectl port-forward` only (see [Observability Access](#observability-access)).

### Step 1 — Install ingress-nginx

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/cloud/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

### Step 2 — Install metrics-server

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
# For kind/minikube (self-signed TLS): add --kubelet-insecure-tls to the metrics-server Deployment
```

### Step 3 — Install ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=120s
```

### Step 4 — Create namespaces

```bash
kubectl create namespace portal-dos-links
kubectl create namespace observability
```

### Step 5 — Apply secrets manually

Secrets are **gitignored** and never committed. See the [Secret Reference](#secret-reference) section for the exact YAML.

```bash
kubectl apply -f k8s/database/secret.yaml
kubectl apply -f k8s/api/secret.yaml
```

### Step 6 — Register observability Applications with ArgoCD

```bash
kubectl apply -f argocd/observability/kube-prometheus-stack-app.yaml
kubectl apply -f argocd/observability/tempo-app.yaml
```

Watch the observability stack sync (wave 0):
```bash
kubectl get application -n argocd kube-prometheus-stack tempo -w
```

Wait for both to show `Synced` + `Healthy` before proceeding.

### Step 7 — Register the portal Application with ArgoCD

```bash
kubectl apply -f argocd/application.yaml
```

Watch sync (wave 1):
```bash
kubectl get application -n argocd portal-dos-links -w
```

Verify all pods healthy:
```bash
kubectl get pods -n portal-dos-links
kubectl get pods -n observability
```

Expected portal pods:
```
NAME                               READY   STATUS    RESTARTS
portal-api-xxx                     1/1     Running   0
portal-api-xxx                     1/1     Running   0
portal-frontend-xxx                1/1     Running   0
portal-frontend-xxx                1/1     Running   0
postgres-xxx                       1/1     Running   0
otel-collector-xxx                 1/1     Running   0
otel-collector-xxx                 1/1     Running   0
```

### Step 8 — Access the ArgoCD UI (optional)

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open `https://localhost:8080`. Accept the self-signed certificate warning and log in with `admin` and the password above.

## How to Deploy a New Version

The application repo CI automatically bumps image tags via the `update-manifests` job. For a manual deploy, update the tag in `k8s/kustomization.yaml`:

```yaml
images:
  - name: ghcr.io/cloudops-squad-2/portal-dos-links-api
    newTag: "abc1234"   # ← replace with the new git SHA
  - name: ghcr.io/cloudops-squad-2/portal-dos-links-frontend
    newTag: "abc1234"
```

Commit and push to `develop`. ArgoCD detects the change within ~3 minutes and rolls out the new version automatically.

---

## Secret Reference

These files are **gitignored**. Create them locally on each machine that needs to bootstrap the cluster.

**`k8s/database/secret.yaml`**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
  namespace: portal-dos-links
type: Opaque
stringData:
  POSTGRES_USER: portal
  POSTGRES_PASSWORD: <your-password>
  POSTGRES_DB: portal       # must match the database name in DATABASE_URL
```

**`k8s/api/secret.yaml`**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: api-secret
  namespace: portal-dos-links
type: Opaque
stringData:
  DATABASE_URL: "postgres://portal:<your-password-url-encoded>@postgres-svc:5432/portal"
```

> **Important:**
> - The key name is `DATABASE_URL` — the API calls `getOrThrow('DATABASE_URL')` and will not start without it.
> - Use `postgres-svc` as the hostname — **not** `localhost`. That is the Kubernetes Service name the API uses inside the cluster.
> - The database name in `DATABASE_URL` (`portal`) **must match** `POSTGRES_DB` in the database secret.
> - The password in `DATABASE_URL` **must match** `POSTGRES_PASSWORD` in the database secret.
> - **URL-encode the password:** special characters must be percent-encoded (e.g. `@` → `%40`, `#` → `%23`, `!` → `%21`). A password with unencoded special characters will cause a connection parse error.
> - See `k8s/api/secret.example.yaml` for a ready-to-copy template.

---

## Observability Architecture

The portal ships end-to-end observability: traces from the browser and the API, metrics from the API and the OTel Collector itself, and a Grafana dashboard with alerts.

```
Browser ──POST /otlp/v1/traces──► Ingress (/otlp, rate-limited)
                                       │
                                       ▼ :4318 HTTP
API pods ──OTLP gRPC:4317────────► OTel Collector (portal-dos-links ns)
                                       │  memory_limiter → batch
                              ┌────────┴──────────────────┐
                              ▼                           ▼
                      Tempo :4317 gRPC             Prometheus :8889
                   (observability ns)              ServiceMonitor
                                                        │
                                                        ▼
                                                  Prometheus + Grafana
                                               (kube-prometheus-stack,
                                                observability ns)
```

**Components:**

| Component | Namespace | Managed by |
|---|---|---|
| OTel Collector (2+ replicas) | `portal-dos-links` | Kustomize / ArgoCD |
| Grafana dashboard ConfigMap | `portal-dos-links` | Kustomize / ArgoCD |
| PrometheusRule (alerts) | `portal-dos-links` | Kustomize / ArgoCD |
| Prometheus + Grafana + kube-state-metrics | `observability` | Helm / ArgoCD (wave 0) |
| Tempo (single-binary) | `observability` | Helm / ArgoCD (wave 0) |

**Key env vars on the API:**

| Variable | Value |
|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-collector:4317` |
| `OTEL_SERVICE_NAME` | `portal-dos-links-api` |
| `OTEL_SEMCONV_STABILITY_OPT_IN` | `http` |
| `OTEL_METRIC_EXPORT_INTERVAL` | `30000` (ms) |

---

## Observability Access

Prometheus, Grafana, and Tempo are **never exposed via public Ingress**. Use `kubectl port-forward`:

```bash
# Grafana (admin / prom-operator by default in kube-prometheus-stack)
kubectl port-forward svc/kube-prometheus-stack-grafana -n observability 3000:80

# Prometheus
kubectl port-forward svc/kube-prometheus-stack-prometheus -n observability 9090:9090

# Tempo (query API)
kubectl port-forward svc/tempo -n observability 3200:3200
```

Open in browser: Grafana at `http://localhost:3000`, Prometheus at `http://localhost:9090`.

> **Dashboard:** the "Portal dos Links" dashboard is auto-discovered by the Grafana sidecar from the `grafana-portal-dashboard` ConfigMap in namespace `portal-dos-links`.

---

## CI Pipeline

Every push to `main` or `develop` and every PR triggers `.github/workflows/ci.yaml`:

1. **Gitleaks** — scans for accidentally committed secrets
2. **kustomize build** — renders the full manifest to `rendered.yaml`
3. **kubeconform** — validates rendered YAML against Kubernetes schemas in strict mode, including CRD schemas for ServiceMonitor, PrometheusRule, HPA, and PodDisruptionBudget

> **Note:** ArgoCD syncs independently of CI. A failing pipeline does not block ArgoCD from syncing the last committed state.

---

## Troubleshooting

### ArgoCD shows `kustomization.yaml is empty` or `ComparisonError`

ArgoCD reads from Git — not your local files. The manifests haven't been pushed to `develop` yet.

```bash
git status                  # check for uncommitted changes
git log --oneline -5        # confirm you're on the right branch
git push origin develop
```

---

### Namespace not found when applying secrets

```
Error from server (NotFound): namespaces "portal-dos-links" not found
```

Create the namespace first:

```bash
kubectl create namespace portal-dos-links
```

---

### Pods stuck in `ImagePullBackOff` or `ErrImagePull`

The cluster cannot pull from `ghcr.io`. The registry may be private. Create an image pull secret:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<github-pat-with-read:packages> \
  --namespace portal-dos-links
```

Then add to the affected deployment under `spec.template.spec`:

```yaml
imagePullSecrets:
  - name: ghcr-pull-secret
```

---

### Pods in `CrashLoopBackOff` — app starts but keeps restarting

The app itself is starting but being killed. Get the logs from the previous (crashed) container:

```bash
kubectl logs -n portal-dos-links deployment/portal-api --previous
kubectl logs -n portal-dos-links deployment/portal-frontend --previous
```

Common causes:

| Symptom | Cause | Fix |
|---|---|---|
| API logs show clean startup but pod restarts | Liveness probe failing — wrong port or path | Probe must be `GET /api/health` on port `3000` |
| Frontend restarts ~40s after start | nginx SIGQUIT — probe hitting wrong port | Probe must be `GET /` on port `80` (not `3000`) |
| API crashes with DB connection error | `DATABASE_URL` secret not applied, using `localhost` as host, or password not URL-encoded | Apply secret; use `postgres-svc` as hostname; URL-encode special chars in password |
| Database pod crashes immediately | `postgres-secret` not applied | Apply `k8s/database/secret.yaml` first |

---

### Pods stuck in `Pending`

The pod can't be scheduled. Describe it to see why:

```bash
kubectl describe pod -n portal-dos-links <pod-name>
```

Common causes:
- `Insufficient cpu` or `Insufficient memory` — cluster doesn't have enough resources. Lower requests in the deployment or add nodes
- `no persistent volumes available` — no `StorageClass` available for the PVC. Check with `kubectl get storageclass`
- `Unschedulable: 0/1 nodes are available` — only one node and it has taints. Check with `kubectl describe nodes`

---

### ArgoCD sync stuck in `Progressing` or never reaches `Synced`

First check the sync details in the UI or CLI:

```bash
kubectl describe application -n argocd portal-dos-links
```

Force a re-sync:

```bash
kubectl patch application portal-dos-links -n argocd \
  --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'
```

Or in the ArgoCD UI: **Sync → Force**.

If the error is about a missing resource (e.g. CRD not installed), install the dependency first.

---

### ArgoCD shows `OutOfSync` right after syncing

Usually means `selfHeal` is fighting a manual `kubectl apply`. ArgoCD will revert any manual changes — this is by design. Always make changes through Git, never directly with `kubectl` on managed resources.

---

### `kustomize build k8s/` fails locally

Check if `observability` is listed in `k8s/kustomization.yaml` before the directory exists:

```yaml
resources:
  - api
  - frontend
  - database
  # - observability   ← keep commented until observability manifests are created
```

Also make sure each subdirectory has its own `kustomization.yaml`. Kustomize requires it for every directory listed as a resource.

---

### Application repo CI fails to push tag bump to this repo

The `update-manifests` job needs `CONFIG_REPO_PAT` set as a secret in the application repo. The PAT must have `contents: write` permission on this repository. Also ensure `yq` is installed in that job before the bump step.

---

### Observability — no data in Grafana panels

1. Check that the OTel Collector pods are running:
   ```bash
   kubectl get pods -n portal-dos-links -l app=otel-collector
   ```
2. Verify the Collector is receiving metrics:
   ```bash
   kubectl exec -n portal-dos-links deploy/otel-collector -- \
     wget -qO- http://localhost:8889/metrics | grep -E '^# TYPE (http|links)'
   ```
   If no output: the API is not sending metrics — check `OTEL_EXPORTER_OTLP_ENDPOINT` in the API pods.
3. Check the ServiceMonitor is discovered by Prometheus:
   ```bash
   kubectl port-forward svc/kube-prometheus-stack-prometheus -n observability 9090:9090
   # Open http://localhost:9090/targets and look for otel-collector
   ```
4. Check the Grafana datasource UID matches the dashboard variable. In Grafana: Configuration → Data Sources → Prometheus → copy the UID, verify it matches `${datasource}` variable default.

---

### Observability — Collector pods OOMKilled

The memory_limiter is configured at 80% / spike 20% of the 512Mi limit. If OOMKill still occurs:
1. Check container memory: `kubectl top pods -n portal-dos-links -l app=otel-collector`
2. Increase `limits.memory` in `k8s/observability/otel-collector-deployment.yaml` (e.g. to 768Mi)
3. Adjust `limit_percentage` accordingly in the ConfigMap

---

### Observability — Tempo not receiving spans

1. Check Collector export errors:
   ```bash
   kubectl logs -n portal-dos-links deploy/otel-collector | grep -i "tempo\|export\|failed"
   ```
2. Verify Tempo is running:
   ```bash
   kubectl get pods -n observability -l app.kubernetes.io/name=tempo
   ```
3. Check Collector can reach Tempo:
   ```bash
   kubectl exec -n portal-dos-links deploy/otel-collector -- \
     wget -qO- http://tempo.observability.svc.cluster.local:3200/ready
   ```
   Expected: `ready`

---

### Observability — otelcol_exporter_send_failed_spans > 0

The `CollectorExportFailures` alert has fired. Check:
1. Tempo pod health (see above)
2. Collector logs for TLS or connection errors
3. Whether the sending queue is full: `otelcol_exporter_queue_size` metric in Prometheus

---

### ArgoCD UI login — `argocd-initial-admin-secret` not found

The secret is deleted after the first login on some installations. Reset the password:

```bash
argocd admin initial-password -n argocd
# or reset via bcrypt:
kubectl -n argocd patch secret argocd-secret \
  -p '{"stringData":{"admin.password":"<bcrypt-hash>","admin.passwordMtime":"'$(date +%FT%T%Z)'"}}'
```

---

## How Kiro Was Used

This repository was built with [Kiro](https://kiro.aws) as AI copilot throughout the hackathon. Key contributions:

| Area | How Kiro helped |
|---|---|
| Spec & design | Generated requirements, design doc and task breakdown from the hackathon PDF |
| K8s manifests | Scaffolded all Deployments, Services, ConfigMaps, PVCs and Ingresses |
| Debugging | Diagnosed probe misconfiguration (wrong ports/paths) from pod logs in real time |
| Architecture | Identified Ingress rewrite breaking frontend static assets — split into two Ingresses |
| Best practices | Moved `DATABASE_URL` from ConfigMap to Secret; removed dead Vite ConfigMap |
| CI pipeline | Reviewed and improved the GitHub Actions validation workflow |
| GitOps | Wrote the ArgoCD Application manifest with automated sync policy |
| Documentation | Generated and maintained this README across multiple iterations |
