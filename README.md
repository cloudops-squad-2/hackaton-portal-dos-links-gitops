# Portal dos Links — GitOps Config Repo

> "A stack todo mundo tem. O portal é só seu."

This repository is the **source of truth** for the Kubernetes cluster that runs **Portal dos Links**, a creative cloud-native link shortener built for the CloudOps Bootcamp Hackathon.

ArgoCD watches this repo and reconciles the cluster with whatever is on the `develop` branch. You do not `kubectl apply` app manifests by hand: push to Git and let ArgoCD do the work.

## Table of Contents

- [The Application](#the-application)
- [Repo Structure](#repo-structure)
- [Prerequisites](#prerequisites)
- [Bootstrap (First-Time Setup)](#bootstrap-first-time-setup)
- [Accessing the Cluster](#accessing-the-cluster)
- [Testing the Deployment](#testing-the-deployment)
- [Day-to-Day Operations](#day-to-day-operations)
- [Secret Reference](#secret-reference)
- [Ingress Layout](#ingress-layout)
- [Observability](#observability)
- [CI Pipeline](#ci-pipeline)
- [Troubleshooting](#troubleshooting)
- [Cleanup](#cleanup)
- [How Kiro Was Used](#how-kiro-was-used)

---

## The Application

| Component | Image | Port | Description |
|---|---|---|---|
| **API** | `ghcr.io/cloudops-squad-2/portal-dos-links-api` | 3000 | NestJS: shortens links, handles redirects |
| **Frontend** | `ghcr.io/cloudops-squad-2/portal-dos-links-frontend` | 80 | nginx serving a Vite static build |
| **Database** | `postgres:16-alpine` | 5432 | PostgreSQL: maps short codes to URLs |

---

## Repo Structure

```
.
├── .github/
│   └── workflows/
│       └── ci.yaml                      # Gitleaks + kustomize build + kubeconform
├── .gitignore
├── argocd/
│   ├── application.yaml                 # Portal Application CRD
│   └── observability/
│       ├── kube-prometheus-stack-app.yaml   # ArgoCD App for Prometheus + Grafana (wave 0)
│       ├── kube-prometheus-stack-values.yaml # Helm values for kube-prometheus-stack
│       ├── tempo-app.yaml               # ArgoCD App for Tempo (wave 0)
│       └── tempo-values.yaml            # Helm values for Tempo
├── k8s/
│   ├── kustomization.yaml               # Root: namespace, resources, image tag overrides
│   ├── api/
│   │   ├── configmap.yaml               # Non-sensitive config (OTEL endpoint only)
│   │   ├── deployment.yaml
│   │   ├── hpa.yaml                     # HPA sync-wave "3" (see Troubleshooting)
│   │   ├── kustomization.yaml
│   │   ├── pdb.yaml                     # PodDisruptionBudget
│   │   ├── secret.example.yaml          # Ready-to-copy template (safe to commit)
│   │   ├── secret.yaml                  # DATABASE_URL (gitignored, apply manually)
│   │   └── service.yaml
│   ├── database/
│   │   ├── deployment.yaml
│   │   ├── kustomization.yaml
│   │   ├── migration-job.yaml           # ArgoCD Sync hook wave 1 — runs prisma migrate deploy after Postgres (wave 0), before API (wave 2)
│   │   ├── pvc.yaml                     # 1Gi persistent volume
│   │   ├── secret.example.yaml          # Ready-to-copy template (safe to commit)
│   │   ├── secret.yaml                  # Postgres credentials (gitignored, apply manually)
│   │   └── service.yaml
│   ├── frontend/
│   │   ├── deployment.yaml              # No ConfigMap: Vite bakes env vars at build time
│   │   ├── hpa.yaml
│   │   ├── ingress-api.yaml             # /api   → API (no rewrite)
│   │   ├── ingress-frontend.yaml        # /      → frontend (no rewrite)
│   │   ├── ingress-otlp.yaml            # /otlp  → OTel Collector (rate-limited)
│   │   ├── ingress-redirect.yaml        # /s/.*  → API (regex + rewrite strips /s)
│   │   ├── kustomization.yaml
│   │   ├── pdb.yaml                     # PodDisruptionBudget
│   │   └── service.yaml
│   └── observability/
│       ├── grafana-dashboard-configmap.yaml  # Auto-discovered by Grafana sidecar
│       ├── kustomization.yaml
│       ├── otel-collector-configmap.yaml     # OTEL pipeline config
│       ├── otel-collector-deployment.yaml
│       ├── otel-collector-hpa.yaml
│       ├── otel-collector-pdb.yaml
│       ├── otel-collector-service.yaml       # Ports 4317 (gRPC), 4318 (HTTP), 8889 (metrics)
│       ├── otel-collector-servicemonitor.yaml # Prometheus scrape config
│       └── prometheus-rule.yaml              # Alerting rules
└── README.md
```

---

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| [`kubectl`](https://kubernetes.io/docs/tasks/tools/) | any recent | Kubernetes CLI |
| [`kustomize`](https://kubectl.docs.kubernetes.io/installation/kustomize/) | >= 5.4.3 | Renders manifests |
| [`helm`](https://helm.sh/docs/intro/install/) | >= 3.14 | Required for the observability stack |
| [`argocd` CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/) | optional | Manage ArgoCD from the terminal |
| Kubernetes cluster | n/a | kind, minikube (recommended: 4 CPUs, 6 GiB RAM), or remote |
| `metrics-server` | n/a | **Required** for HPAs to work. Most managed clusters include it; for kind/minikube see Step 3 below |
| GHCR access | n/a | Pull access to `ghcr.io/cloudops-squad-2/` |

---

## Bootstrap (First-Time Setup)

Run everything from the repo root, **in this order**, to avoid dependency failures:

1. ingress-nginx (all Ingresses depend on it)
2. metrics-server (HPAs depend on it)
3. ArgoCD (sync controller)
4. Namespaces (so secrets can be applied before the first sync)
5. Secrets (manual, gitignored, never committed)
6. Observability stack (sync-wave 0: kube-prometheus-stack + Tempo, which create the CRDs the portal needs)
7. Portal Application (sync-wave 1)

> **Note:** Prometheus, Grafana, and Tempo are **never exposed via public Ingress**. Use `kubectl port-forward` only (see [Accessing the Cluster](#accessing-the-cluster)).

### Step 0 — Pre-flight check

The HPA sync-wave fix must be on `develop`, otherwise a fresh install stalls on the API's HPA.

```bash
git fetch origin
git show origin/develop:k8s/api/hpa.yaml | grep -n sync-wave
```

You should see `argocd.argoproj.io/sync-wave: "3"`. If nothing prints, merge the fix into `develop` first.

### Step 1 — Start a cluster (local only)

Skip this if you already have a cluster.

```bash
minikube start --driver=docker --cpus=4 --memory=6144
kubectl get nodes          # should show Ready
```

### Step 2 — Install ingress-nginx

**Minikube:** use the addon. The `provider/cloud` manifest leaves Ingresses without an address on minikube.

```bash
minikube addons enable ingress
kubectl wait -n ingress-nginx --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=180s
kubectl get svc -n ingress-nginx ingress-nginx-controller   # TYPE should be NodePort
```

**Cloud / remote cluster:**

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/cloud/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

### Step 3 — Install metrics-server

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

**kind / minikube only** (self-signed kubelet TLS), add `--kubelet-insecure-tls`:

```bash
kubectl patch deploy metrics-server -n kube-system --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

### Step 4 — Install ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s
```

`--server-side` avoids the "annotation too long" error on ArgoCD's large CRDs.

### Step 5 — Create namespaces

```bash
kubectl create namespace portal-dos-links
kubectl create namespace observability
```

### Step 6 — Create secrets

Secrets are **gitignored** and never committed. The password must match in both. See the [Secret Reference](#secret-reference) for the exact YAML.

**Option A:** apply your local files:

```bash
kubectl apply -f k8s/database/secret.yaml
kubectl apply -f k8s/api/secret.yaml
```

**Option B:** create them directly (demo values shown; use a real password outside local dev):

```bash
kubectl create secret generic postgres-secret -n portal-dos-links \
  --from-literal=POSTGRES_USER=portal \
  --from-literal=POSTGRES_PASSWORD=demo1234 \
  --from-literal=POSTGRES_DB=portal

kubectl create secret generic api-secret -n portal-dos-links \
  --from-literal=DATABASE_URL='postgres://portal:demo1234@postgres-svc:5432/portal'
```

### Step 7 — Deploy the observability stack (wave 0)

```bash
kubectl apply -f argocd/observability/kube-prometheus-stack-app.yaml
kubectl apply -f argocd/observability/tempo-app.yaml
kubectl get application -n argocd -w      # wait for Synced + Healthy, then Ctrl+C
```

Wait for both Applications to show `Synced` + `Healthy` before continuing.

### Step 8 — Deploy the portal (wave 1)

```bash
kubectl apply -f argocd/application.yaml
kubectl get application -n argocd portal-dos-links -w   # wait for Synced + Healthy
```

Inside the portal Application, resources sync in waves. This can take a few minutes:

| Wave | Resources |
|---|---|
| 0 | postgres, frontend, OTel Collector |
| 1 | `prisma-migrate` Job (Sync hook — runs after wave 0 is Healthy, before wave 2) |
| 2 | API |
| 3 | API HPA |

### Step 9 — Verify

```bash
kubectl get pods -n portal-dos-links      # api x2, frontend x2, postgres, otel-collector x2
kubectl get pods -n observability
kubectl get ingress -n portal-dos-links   # HOSTS = *, ADDRESS populated (minikube: 192.168.49.2)
kubectl get hpa -n portal-dos-links       # portal-api-hpa shows CPU numbers, not <unknown>
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

---

## Accessing the Cluster

### Port map

Each port-forward needs its own terminal. If a port is "already in use", run `ss -ltnp | grep 8081` and then `kill <pid>`.

| Local port | Service | URL |
|---|---|---|
| **8080** | ArgoCD | https://localhost:8080 (accept the self-signed certificate warning) |
| **8081** | Portal (via ingress) | http://localhost:8081 |
| **8082** | Grafana | http://localhost:8082 |
| **8083** | Prometheus | http://localhost:8083 |
| **8084** | Tempo (query API) | http://localhost:8084 |

### Port-forward commands

```bash
# Portal: always the INGRESS controller, never svc/portal-frontend-svc (that causes the 405)
kubectl port-forward svc/ingress-nginx-controller -n ingress-nginx 8081:80

# ArgoCD
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Grafana
kubectl port-forward svc/kube-prometheus-stack-grafana -n observability 8082:80

# Prometheus
kubectl port-forward svc/kube-prometheus-stack-prometheus -n observability 8083:9090

# Tempo
kubectl port-forward svc/tempo -n observability 8084:3200
```

> **Observability is port-forward only.** Prometheus, Grafana, and Tempo are never exposed through a public Ingress.

### Passwords

```bash
# ArgoCD (user: admin)
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo

# Grafana (user: admin, usually prom-operator)
kubectl -n observability get secret kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 -d; echo
```

> **Dashboard:** the "Portal dos Links" dashboard is auto-discovered by the Grafana sidecar from the `grafana-portal-dashboard` ConfigMap in namespace `portal-dos-links`.

---

## Testing the Deployment

```bash
# Create a link, expect 201 Created
curl -i -X POST http://localhost:8081/api/links \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com"}'

# Use the "code" from the response, expect a 302 redirect
curl -i http://localhost:8081/s/<code>
```

Then open http://localhost:8081, hard refresh with **Ctrl+Shift+R**, and create a link from the UI.

---

## Day-to-Day Operations

### Deploy a new version

The application repo's CI bumps image tags automatically via its `update-manifests` job. For a manual deploy, update the tags in `k8s/kustomization.yaml`:

```yaml
images:
  - name: ghcr.io/cloudops-squad-2/portal-dos-links-api
    newTag: "abc1234"   # ← replace with the new git SHA
  - name: ghcr.io/cloudops-squad-2/portal-dos-links-frontend
    newTag: "abc1234"
```

Commit and push to `develop`. ArgoCD detects the change within ~3 minutes and rolls out the new version.

### Force a refresh or retry

```bash
# Pull the latest Git changes without waiting ~3 minutes
kubectl annotate application portal-dos-links -n argocd argocd.argoproj.io/refresh=hard --overwrite

# Restart a sync that gave up after 5 retries
kubectl patch application portal-dos-links -n argocd --type merge \
  -p '{"operation":{"sync":{"prune":true}}}'
```

### Routine checks

```bash
minikube start                                  # after a reboot (local only)
kubectl get pods -A | grep -v Running           # anything unhealthy?
kubectl get application -n argocd               # sync status
```

> **Always change things through Git.** `selfHeal` reverts manual `kubectl` edits on managed resources by design.

---

## Secret Reference

These files are **gitignored**. Create them locally on each machine that bootstraps the cluster.

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
> - The key name is `DATABASE_URL`. The API calls `getOrThrow('DATABASE_URL')` and will not start without it.
> - Use `postgres-svc` as the hostname, **not** `localhost`. That is the Kubernetes Service name inside the cluster.
> - The database name in `DATABASE_URL` (`portal`) **must match** `POSTGRES_DB`.
> - The password in `DATABASE_URL` **must match** `POSTGRES_PASSWORD`.
> - **URL-encode the password.** Special characters must be percent-encoded (`@` → `%40`, `#` → `%23`, `!` → `%21`), otherwise you get a connection parse error.
> - See `k8s/api/secret.example.yaml` for a ready-to-copy template. Copy it, fill in the values, save as `secret.yaml` in the same directory, and apply:
> ```bash
> cp k8s/api/secret.example.yaml k8s/api/secret.yaml
> # edit k8s/api/secret.yaml with your values
> kubectl apply -f k8s/api/secret.yaml
> ```

---

## Ingress Layout

Four separate Ingress objects live in `k8s/frontend/`. Each concern has its own object because the nginx `rewrite-target` annotation applies to the **entire Ingress**. Mixing rewrite and non-rewrite paths in one object would strip paths unintentionally.

| File | Path | Backend | Rewrite |
|---|---|---|---|
| `ingress-frontend.yaml` | `/` (Prefix) | `portal-frontend-svc:80` | None |
| `ingress-api.yaml` | `/api` (Prefix) | `portal-api-svc:3000` | None |
| `ingress-redirect.yaml` | `/s/(.*)` (regex) | `portal-api-svc:3000` | `/$1` (strips `/s`) |
| `ingress-otlp.yaml` | `/otlp` (Prefix) | `otel-collector:4318` | None |

**Why the redirect has its own Ingress:** the API handles `GET /:code` at its root, while `/s` is a public URL convention defined by this GitOps repo. `ingress-redirect.yaml` strips `/s` before the request reaches the API, so the API code never needs to change. If `/api` shared that Ingress, the rewrite would also strip `/api` and break every API route.

---

## Observability

The portal ships end-to-end observability: traces from the browser and the API, metrics from the API and the OTel Collector itself, and a Grafana dashboard with alerts.

### Architecture

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

### Components

| Component | Namespace | Managed by |
|---|---|---|
| OTel Collector (2+ replicas) | `portal-dos-links` | Kustomize / ArgoCD |
| Grafana dashboard ConfigMap | `portal-dos-links` | Kustomize / ArgoCD |
| PrometheusRule (alerts) | `portal-dos-links` | Kustomize / ArgoCD |
| Prometheus + Grafana + kube-state-metrics | `observability` | Helm / ArgoCD (wave 0) |
| Tempo (single-binary) | `observability` | Helm / ArgoCD (wave 0) |

### API environment variables

| Variable | Value |
|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-collector:4317` |
| `OTEL_SERVICE_NAME` | `portal-dos-links-api` |
| `OTEL_SEMCONV_STABILITY_OPT_IN` | `http` |
| `OTEL_METRIC_EXPORT_INTERVAL` | `30000` (ms) |

### Access

Port-forward only, never public Ingress. See [Accessing the Cluster](#accessing-the-cluster) for commands (Grafana on `8082`, Prometheus on `8083`, Tempo on `8084`).

---

## CI Pipeline

Every push to `main` or `develop`, and every PR, triggers `.github/workflows/ci.yaml`:

1. **Gitleaks**: scans for accidentally committed secrets
2. **kustomize build**: renders the full manifest to `rendered.yaml`
3. **kubeconform**: validates the rendered YAML against Kubernetes schemas in strict mode, including CRD schemas for ServiceMonitor, PrometheusRule, HPA, and PodDisruptionBudget

> **Note:** ArgoCD syncs independently of CI. A failing pipeline does not block ArgoCD from syncing the last committed state.

### Automated image tag bumps (`CONFIG_REPO_PAT`)

The application repo's `update-manifests` job automatically bumps image tags in `k8s/kustomization.yaml` after every successful build. For this to work:

1. **Create a GitHub PAT** with `contents: write` scope on **this** repository (Settings → Developer settings → Personal access tokens → Fine-grained).
2. **Add it as a secret** named `CONFIG_REPO_PAT` in the **application** repo (Settings → Secrets and variables → Actions).
3. **Ensure `yq` is installed** in the `update-manifests` job before the bump step:
   ```yaml
   - name: Install yq
     run: |
       curl -fsSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
         -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq
   ```
4. **Branch protection:** if `develop` requires PRs, either allow the bot to bypass protection or configure the job to open a PR instead of pushing directly.

Once set up, pushing to `develop` on the application repo triggers the full loop: build → push image → bump tag here → ArgoCD detects diff → deploy.

---

## Troubleshooting

- [Quick reference](#quick-reference)
- [ArgoCD and sync](#argocd-and-sync)
- [Pods](#pods)
- [Networking and Ingress](#networking-and-ingress)
- [Database and migrations](#database-and-migrations)
- [Observability](#observability-troubleshooting)
- [Misc](#misc)

### Quick reference

| Symptom | Cause | Fix |
|---|---|---|
| `405` on `POST /api/links` | Port-forwarding the frontend Service, which skips the Ingress | Forward `svc/ingress-nginx-controller` |
| `503` on `/api`, no `portal-api` pods | Sync stuck or failed before the API wave | [Find why the sync is stuck](#find-why-a-sync-is-stuck) |
| `Empty reply from server` | Stale port-forward holding the port | `ss -ltnp \| grep <port>`, kill it, restart |
| `404` from nginx on localhost | Ingress has a `host:` restriction | Check that `kubectl get ingress` shows HOSTS `*` |
| Ingress `ADDRESS` empty, ArgoCD waits on Ingresses | Controller is a `LoadBalancer` stuck on `<pending>` (cloud manifest on minikube) | Use `minikube addons enable ingress` |
| Sync `Failed`, HPA says "target not found" | HPA is in wave 0 but the Deployment is wave 2 | Give `k8s/api/hpa.yaml` the annotation `argocd.argoproj.io/sync-wave: "3"`, merge into `develop`, refresh |
| Live HPA has no `sync-wave` annotation | ArgoCD is syncing a revision without the fix | Confirm the fix is on `develop`, then refresh and sync |
| Change in Git has no effect | ArgoCD tracks `develop` | Merge into `develop`, then refresh |
| Pod `CrashLoopBackOff` | App error or bad secret | `kubectl logs -n portal-dos-links deploy/portal-api --previous` |
| Port-forward died after sleep or restart | Connection dropped | Ctrl+C and run it again |

### ArgoCD and sync

#### `kustomization.yaml is empty` or `ComparisonError`

ArgoCD reads from Git, not your local files. Push your changes to the branch ArgoCD tracks (`develop`):

```bash
git status                  # check for uncommitted changes
git log --oneline -5        # confirm you're on the right branch
git push origin develop
```

#### Find why a sync is stuck

```bash
kubectl get application portal-dos-links -n argocd \
  -o jsonpath='{.status.operationState.phase}{"\n"}{.status.operationState.message}{"\n"}'

kubectl get application portal-dos-links -n argocd \
  -o jsonpath='{range .status.operationState.syncResult.resources[*]}{.kind}{"\t"}{.name}{"\t"}{.status}{"\t"}{.hookPhase}{"\t"}{.message}{"\n"}{end}' \
  | column -t -s$'\t' | grep -v " Succeeded "
```

Look for rows with a `Failed` hook phase. You can also run `kubectl describe application -n argocd portal-dos-links`.

#### Sync stuck in `Progressing` or never reaches `Synced`

Force a re-sync:

```bash
kubectl patch application portal-dos-links -n argocd \
  --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'
```

Or in the ArgoCD UI: **Sync → Force**. If the error is about a missing resource (for example a CRD), install the dependency first.

#### `OutOfSync` right after syncing

Usually `selfHeal` fighting a manual `kubectl apply`. ArgoCD reverts manual changes by design. Make changes through Git.

#### Checking that the HPA fix reached the cluster

```bash
kubectl get hpa portal-api-hpa -n portal-dos-links \
  -o jsonpath='{.metadata.annotations}{"\n"}'   # should include sync-wave "3"
kubectl get application portal-dos-links -n argocd \
  -o jsonpath='{.spec.source.targetRevision}{"\n"}{.status.sync.revision}{"\n"}'
```

#### `kustomize build` fails because `observability` doesn't exist yet

Check whether `observability` is listed in `k8s/kustomization.yaml` before the directory exists:

```yaml
resources:
  - api
  - frontend
  - database
  # - observability   ← keep commented until observability manifests are created
```

Every directory listed as a resource also needs its own `kustomization.yaml`.

#### ArgoCD login: password lost or `argocd-initial-admin-secret` not found

The initial secret is deleted after the first login on some installations. Reset the password (this example resets it to `admin123`, so change it after logging in):

```bash
kubectl -n argocd patch secret argocd-secret \
  -p '{"stringData": {"admin.password": "$2a$10$rRyBsGSHK6.uc8fntPwVIuLVHgsAhAX7TcdrqW/9mu5rmiOblyutS", "admin.passwordMtime": "'$(date +%FT%T%Z)'"}}'
kubectl rollout restart deployment/argocd-server -n argocd
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=argocd-server -n argocd --timeout=60s

# log in with admin / admin123, then change the password
argocd login localhost:8080 --insecure --username admin --password admin123
```

Alternatively: `argocd admin initial-password -n argocd`.

#### Application repo CI fails to push the tag bump

The `update-manifests` job needs `CONFIG_REPO_PAT` set as a secret in the **application** repo. The PAT must have `contents: write` on this repository. Also make sure `yq` is installed in that job before the bump step.

### Pods

#### `Namespace not found` when applying secrets

```
Error from server (NotFound): namespaces "portal-dos-links" not found
```

```bash
kubectl create namespace portal-dos-links
```

#### `ImagePullBackOff` / `ErrImagePull`

The cluster cannot pull from `ghcr.io`, and the registry may be private. Create an image pull secret:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<github-pat-with-read:packages> \
  --namespace portal-dos-links
```

Then add it to the affected Deployment under `spec.template.spec`:

```yaml
imagePullSecrets:
  - name: ghcr-pull-secret
```

#### `CrashLoopBackOff`: app starts but keeps restarting

Get logs from the previous (crashed) container:

```bash
kubectl logs -n portal-dos-links deployment/portal-api --previous
kubectl logs -n portal-dos-links deployment/portal-frontend --previous
```

| Symptom | Cause | Fix |
|---|---|---|
| API logs show clean startup but pod restarts | Liveness probe failing (wrong port or path) | Probe must be `GET /api/health` on port `3000` |
| Frontend restarts ~40s after start | nginx SIGQUIT: probe hitting the wrong port | Probe must be `GET /` on port `80` (not `3000`) |
| API crashes with a DB connection error | `DATABASE_URL` secret not applied, `localhost` used as host, or password not URL-encoded | Apply the secret, use `postgres-svc` as hostname, URL-encode special characters |
| Database pod crashes immediately | `postgres-secret` not applied | Apply `k8s/database/secret.yaml` first |

#### Pods stuck in `Pending`

```bash
kubectl describe pod -n portal-dos-links <pod-name>
```

- `Insufficient cpu` / `Insufficient memory`: the cluster is too small. Lower requests in the Deployment or add nodes.
- `no persistent volumes available`: no `StorageClass` for the PVC. Check `kubectl get storageclass`.
- `Unschedulable: 0/1 nodes are available`: single node with taints. Check `kubectl describe nodes`.

### Networking and Ingress

#### `POST /api/links` returns `405 Not Allowed` in the browser

**Symptom:** the frontend loads but creating a link fails. DevTools shows `405 Not Allowed` on `POST /api/links` with `Server: nginx/<version>` and an HTML body.

**Cause:** the request is answered by the **frontend's static nginx**, not the API. Routing `/api` to the API exists only in the Ingress objects, which a direct port-forward to the frontend Service bypasses. A static nginx rejects `POST` on any path with 405.

| Symptom | Cause | Fix |
|---|---|---|
| `405` from `nginx/1.x.x` (versioned), HTML body | Port-forward points at `svc/portal-frontend-svc` | Port-forward the ingress controller instead |
| `404` from `nginx` (no version) on `localhost` | Ingress rules have a `host:` (e.g. `portal.localdev`) that doesn't match | Remove `host:` from the Ingresses or send a matching `Host` header |
| `curl: (52) Empty reply from server` | Stale port-forward holding the port | Stop the old port-forward, check with `ss -ltnp \| grep <port>`, restart |
| Fix pushed but cluster unchanged | ArgoCD tracks `develop` and the fix is on another branch | Merge into `develop`, then force a refresh |

**Fix:** access the app through the Ingress controller:

```bash
kubectl port-forward svc/ingress-nginx-controller -n ingress-nginx 8081:80
```

Open `http://localhost:8081`. Routing is then `/` → frontend, `/api` → API, `/s/<code>` → API (rewritten to `/<code>`).

**Verify:**

```bash
# Ingresses should show HOSTS = *
kubectl get ingress -n portal-dos-links

# API through the Ingress should return 201
curl -i -X POST http://localhost:8081/api/links \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com"}'
```

If you changed an Ingress and nothing happens, ArgoCD only syncs `targetRevision` (`develop`). Merge the change, then run the hard refresh from [Day-to-Day Operations](#force-a-refresh-or-retry).

> **Tip:** a `405` with a versioned `Server: nginx/1.x.x` header and an HTML body means a static file server answered. ingress-nginx responds with just `Server: nginx`.

#### `/s/<code>` returns 404

The redirect path is handled by `ingress-redirect.yaml`, which uses regex and rewrite.

1. Confirm the Ingress exists with the correct annotations. Expected: `use-regex: "true"` and `rewrite-target: /$1`.
   ```bash
   kubectl get ingress portal-redirect-ingress -n portal-dos-links -o yaml | grep -A5 annotations
   ```
2. Confirm `pathType: ImplementationSpecific`. ingress-nginx needs it for regex paths; with `Prefix` the regex is not evaluated.
3. Check for conflicting Ingresses on the same host. ingress-nginx merges all Ingresses sharing a host into one server block, so an earlier Ingress with a catch-all `rewrite-target` can shadow this one.
   ```bash
   kubectl get ingress -n portal-dos-links
   ```
4. Verify the API receives the rewritten path. You should see `GET /<code>`, not `GET /s/<code>`.
   ```bash
   kubectl logs -n portal-dos-links deployment/portal-api | grep "GET /"
   ```

### Database and migrations

Check the migration Job first:

```bash
kubectl get jobs -n portal-dos-links
kubectl logs -n portal-dos-links job/prisma-migrate
```

| Error | Cause | Fix (in the **application** repo) |
|---|---|---|
| `Cannot find module 'dotenv/config'` | `prisma7.config.ts` imports `dotenv`, a devDependency pruned from the production image | Remove the `dotenv/config` import from `prisma7.config.ts`, or move `dotenv` to production dependencies |
| `Could not find Prisma Schema` | The `prisma/` folder was not copied into the production image | Add to the `prod` stage of the Dockerfile: `COPY --from=build --chown=node:node /app/prisma ./prisma` |
| `datasource.url property is required` | Prisma 7 needs `DATABASE_URL` passed explicitly | Include `--url=$(DATABASE_URL)` in the migration Job command, or configure it in `prisma7.config.ts` |

### Observability troubleshooting

#### No data in Grafana panels

1. Check that the OTel Collector pods are running:
   ```bash
   kubectl get pods -n portal-dos-links -l app=otel-collector
   ```
2. Verify the Collector is receiving metrics. If there is no output, the API is not sending metrics: check `OTEL_EXPORTER_OTLP_ENDPOINT` in the API pods.
   ```bash
   kubectl exec -n portal-dos-links deploy/otel-collector -- \
     wget -qO- http://localhost:8889/metrics | grep -E '^# TYPE (http|links)'
   ```
3. Check that Prometheus discovered the ServiceMonitor. Open http://localhost:8083/targets and look for `otel-collector`.
   ```bash
   kubectl port-forward svc/kube-prometheus-stack-prometheus -n observability 8083:9090
   ```
4. Check that the Grafana datasource UID matches the dashboard variable. In Grafana: Configuration → Data Sources → Prometheus → copy the UID and verify it matches the `${datasource}` variable default.

#### Collector pods `OOMKilled`

The `memory_limiter` is configured at 80% / spike 20% of the 512Mi limit. If OOMKills still occur:

1. Check container memory: `kubectl top pods -n portal-dos-links -l app=otel-collector`
2. Increase `limits.memory` in `k8s/observability/otel-collector-deployment.yaml` (e.g. to 768Mi).
3. Adjust `limit_percentage` accordingly in the ConfigMap.

#### Tempo not receiving spans

1. Check Collector export errors:
   ```bash
   kubectl logs -n portal-dos-links deploy/otel-collector | grep -i "tempo\|export\|failed"
   ```
2. Verify Tempo is running:
   ```bash
   kubectl get pods -n observability -l app.kubernetes.io/name=tempo
   ```
3. Check that the Collector can reach Tempo (expected output: `ready`):
   ```bash
   kubectl exec -n portal-dos-links deploy/otel-collector -- \
     wget -qO- http://tempo.observability.svc.cluster.local:3200/ready
   ```

#### `otelcol_exporter_send_failed_spans` > 0

The `CollectorExportFailures` alert has fired. Check:

1. Tempo pod health (see above).
2. Collector logs for TLS or connection errors.
3. Whether the sending queue is full: look at the `otelcol_exporter_queue_size` metric in Prometheus.

### Misc

#### `sudo kubectl port-forward` can't find the cluster

`sudo` does not inherit your kubeconfig (on WSL it drops your user environment). Pass it explicitly:

```bash
sudo kubectl port-forward svc/portal-api-svc 80:3000 \
  --kubeconfig /home/<your-user>/.kube/config
```

---

## Cleanup

```bash
minikube stop      # pause, keeps everything
minikube delete    # wipe the whole cluster
```

---

## How Kiro Was Used

This repository was built with [Kiro](https://kiro.aws) as an AI copilot throughout the hackathon:

| Area | How Kiro helped |
|---|---|
| Spec & design | Generated requirements, design doc and task breakdown from the hackathon PDF |
| K8s manifests | Scaffolded all Deployments, Services, ConfigMaps, PVCs and Ingresses |
| Debugging | Diagnosed probe misconfiguration (wrong ports/paths) from pod logs in real time |
| Architecture | Identified an Ingress rewrite breaking frontend static assets and split it into separate Ingresses |
| Best practices | Moved `DATABASE_URL` from ConfigMap to Secret; removed the dead Vite ConfigMap |
| CI pipeline | Reviewed and improved the GitHub Actions validation workflow |
| GitOps | Wrote the ArgoCD Application manifest with automated sync policy |
| Documentation | Generated and maintained this README across multiple iterations |