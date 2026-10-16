# Design — GitOps Config Repo (Portal dos Links)

## Repository Layout

```
hackaton-portal-dos-links-gitops/
├── argocd/
│   └── application.yaml            # ArgoCD Application CRD
├── k8s/
│   ├── kustomization.yaml          # Root — namespace, resources, image tag overrides
│   ├── api/
│   │   ├── configmap.yaml          # Non-sensitive config (OTEL endpoint)
│   │   ├── secret.yaml             # DATABASE_URL — gitignored, applied manually
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── kustomization.yaml
│   ├── frontend/
│   │   ├── deployment.yaml         # No ConfigMap — Vite bakes env vars at build time
│   │   ├── service.yaml
│   │   ├── ingress-api.yaml        # Rewrite ingress for /api and /s paths
│   │   ├── ingress-frontend.yaml   # Plain ingress for / path (no rewrite)
│   │   └── kustomization.yaml
│   ├── database/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── secret.yaml             # Gitignored, applied manually
│   │   ├── pvc.yaml
│   │   └── kustomization.yaml
│   └── observability/              # ⏳ Pending — OTEL Collector + Grafana
│       ├── kustomization.yaml
│       ├── otel-collector-deployment.yaml
│       ├── otel-collector-service.yaml
│       ├── otel-collector-configmap.yaml
│       └── grafana-dashboard-configmap.yaml
├── .github/
│   └── workflows/
│       └── ci.yaml                 # Gitleaks + kustomize build + kubeconform
├── .gitignore
└── README.md
```

---

## Namespace Strategy

All resources live in a single namespace: **`portal-dos-links`**.
The ArgoCD Application carries `CreateNamespace=true` so no manual bootstrapping is needed.
Secrets are gitignored and must be applied manually before the first sync.

---

## Kustomize Image Override Pattern

The root `k8s/kustomization.yaml` declares:

```yaml
images:
  - name: ghcr.io/cloudops-squad-2/portal-dos-links-api
    newTag: "756c6d6"     # application repo CI bumps this with the git SHA
  - name: ghcr.io/cloudops-squad-2/portal-dos-links-frontend
    newTag: "756c6d6"
```

The application repo's `update-manifests` job uses `yq` to patch `newTag` and pushes directly to `develop`. ArgoCD detects the change and reconciles automatically.

---

## Component Design

### API

| Field | Value |
|---|---|
| Image | `ghcr.io/cloudops-squad-2/portal-dos-links-api` |
| Port | `3000` (NestJS default) |
| Replicas | `2` |
| Liveness | `GET /api/health` port 3000, after 10s |
| Readiness | `GET /api/health` port 3000, after 5s |
| Env (ConfigMap) | `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317` |
| Env (Secret) | `DATABASE_URL=postgres://portal:<pw>@postgres-svc:5432/portal` |

The API Service is `ClusterIP` on port 3000. The Ingress (with rewrite) routes `/api/*` and `/s/*` to it, stripping the prefix before forwarding.

### Frontend

| Field | Value |
|---|---|
| Image | `ghcr.io/cloudops-squad-2/portal-dos-links-frontend` |
| Port | `80` (nginx serving Vite static build) |
| Replicas | `2` |
| Liveness | `GET /` port 80, after 15s |
| Readiness | `GET /` port 80, after 5s |
| Env | None — Vite bakes env vars at build time, runtime ConfigMap has no effect |

No ConfigMap. The frontend Service is `ClusterIP` on port 80.

### Database (PostgreSQL)

| Field | Value |
|---|---|
| Image | `postgres:16-alpine` |
| Port | `5432` |
| Replicas | `1` (Deployment + PVC) |
| Liveness | `pg_isready -U $(POSTGRES_USER) -d $(POSTGRES_DB)` exec probe, after 15s |
| Readiness | `pg_isready -U $(POSTGRES_USER) -d $(POSTGRES_DB)` exec probe, after 5s |
| Storage | `PersistentVolumeClaim` 1Gi, `ReadWriteOnce` |
| Env (Secret) | `POSTGRES_USER=portal`, `POSTGRES_PASSWORD=<pw>`, `POSTGRES_DB=portal` |

The database Service is `ClusterIP` — never exposed outside the cluster.
The `POSTGRES_DB` value (`portal`) must match the database name in the API's `DATABASE_URL`.

---

## Ingress Design

Split into two Ingress resources to avoid the nginx `rewrite-target` breaking static asset paths:

### `ingress-api.yaml` — with rewrite

```
/api(/|$)(.*) → portal-api-svc:3000  (rewrite: /$2 strips /api prefix)
/s(/|$)(.*)   → portal-api-svc:3000  (rewrite: /$2 strips /s prefix)
```

Annotation: `nginx.ingress.kubernetes.io/rewrite-target: /$2`

### `ingress-frontend.yaml` — no rewrite

```
/ (Prefix) → portal-frontend-svc:80
```

No rewrite annotation — nginx passes the full path through, so `/assets/app.js` reaches nginx correctly.

Hostname: `portal.localdev` for local clusters. Override via Kustomize patch for other environments.

---

## Observability Design (pending)

### OpenTelemetry Collector Pipeline

```
OTLP gRPC (4317)  ──►  batch processor  ──►  Jaeger/Tempo exporter (traces)
                                          └──►  Prometheus exporter (:8889/metrics)
```

The API ConfigMap already sets `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317` — single source of truth, ready when the collector is deployed.

### Grafana Dashboard

A `ConfigMap` labelled `grafana_dashboard: "1"` carries the dashboard JSON. Panels:

1. **Cliques por minuto** — rate of redirect requests
2. **Latência p99** — histogram quantile on request duration
3. **Taxa de erros** — ratio of 5xx responses
4. **Serviços saudáveis** — pod readiness stat panel

---

## ArgoCD Application

```yaml
spec:
  source:
    repoURL: https://github.com/cloudops-squad-2/hackaton-portal-dos-links-gitops.git
    targetRevision: develop   # tracks develop; promote to main for releases
    path: k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: portal-dos-links
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

`prune: true` removes resources deleted from Git. `selfHeal: true` reverts manual `kubectl` changes.

---

## Secret Handling

Secrets (`**/secret.yaml`) are **gitignored** — never committed. Apply manually before first sync:

```bash
kubectl apply -f k8s/database/secret.yaml
kubectl apply -f k8s/api/secret.yaml
```

Upgrade path for production: replace with **Sealed Secrets** CRDs encrypted with the cluster public key, which are safe to commit.

---

## CI Integration (from application repo)

The application repo's `update-manifests` job:

1. Builds and pushes images tagged with the git SHA to `ghcr.io/cloudops-squad-2/`
2. Checks out this config repo on `develop` using `CONFIG_REPO_PAT`
3. Uses `yq` to patch `newTag` in `k8s/kustomization.yaml` for both services
4. Commits and pushes directly to `develop`
5. ArgoCD detects the diff and rolls out the new version automatically

> **Note:** `CONFIG_REPO_PAT` must be a GitHub PAT with `contents: write` on this repo, stored as a secret in the application repo. `yq` must be installed on the runner before the bump step.
