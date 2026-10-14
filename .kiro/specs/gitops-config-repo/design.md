# Design — GitOps Config Repo (Portal dos Links)

## Repository Layout

```
hackaton-portal-dos-links-gitops/
├── argocd/
│   └── application.yaml            # ArgoCD Application CRD
├── k8s/
│   ├── kustomization.yaml          # Root kustomization (namespace + image overrides)
│   ├── api/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── configmap.yaml
│   │   └── secret.yaml
│   ├── frontend/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── configmap.yaml
│   │   └── ingress.yaml
│   ├── database/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── secret.yaml
│   │   └── pvc.yaml
│   └── observability/
│       ├── kustomization.yaml
│       ├── otel-collector-deployment.yaml
│       ├── otel-collector-service.yaml
│       ├── otel-collector-configmap.yaml
│       └── grafana-dashboard-configmap.yaml
└── README.md
```

---

## Namespace Strategy

All resources live in a single namespace: **`portal-dos-links`**.  
The ArgoCD Application carries `CreateNamespace=true` so no manual bootstrapping is needed.

---

## Kustomize Image Override Pattern

The root `k8s/kustomization.yaml` declares:

```yaml
images:
  - name: ghcr.io/<org>/portal-api
    newTag: latest          # CI replaces this with the git SHA
  - name: ghcr.io/<org>/portal-frontend
    newTag: latest
```

The CI pipeline (in the application repo) opens a PR / direct push to this repo bumping only the `newTag` values. ArgoCD detects the change and reconciles.

---

## Component Design

### API

| Field | Value |
|---|---|
| Image | `ghcr.io/<org>/portal-api` |
| Port | `8080` |
| Replicas | `2` |
| Liveness | `GET /healthz` after 10 s |
| Readiness | `GET /readyz` after 5 s |
| Env (ConfigMap) | `OTEL_EXPORTER_OTLP_ENDPOINT`, `DATABASE_URL` key reference |
| Env (Secret) | `DATABASE_PASSWORD` |

The API Service is `ClusterIP`; the Ingress routes `/s/*` (redirect) and `/api/*` (CRUD) to it.

### Frontend

| Field | Value |
|---|---|
| Image | `ghcr.io/<org>/portal-frontend` |
| Port | `3000` |
| Replicas | `2` |
| Liveness | `GET /` after 15 s |
| Readiness | `GET /` after 5 s |
| Env (ConfigMap) | `NEXT_PUBLIC_API_URL` |

Ingress catches `/*` and routes to the frontend service. The `/api` and `/s` prefixes match earlier Ingress rules for the API.

### Database (PostgreSQL)

| Field | Value |
|---|---|
| Image | `postgres:16-alpine` |
| Port | `5432` |
| Replicas | `1` (StatefulSet pattern via Deployment + PVC) |
| Liveness | `pg_isready` exec probe |
| Readiness | `pg_isready` exec probe |
| Storage | `PersistentVolumeClaim` 1 Gi, `ReadWriteOnce` |
| Env (Secret) | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` |

The database Service is `ClusterIP` — never exposed outside the cluster.

---

## Observability Design

### OpenTelemetry Collector Pipeline

```
OTLP gRPC (4317)  ──►  batch processor  ──►  Jaeger/Tempo exporter (traces)
                                          └──►  Prometheus exporter (:8889/metrics)
```

The collector `ConfigMap` defines the full pipeline. Both the `api` and `frontend` deployments point `OTEL_EXPORTER_OTLP_ENDPOINT` to `http://otel-collector:4317` — a single ConfigMap value, no duplication.

### Grafana Dashboard

A `ConfigMap` labelled `grafana_dashboard: "1"` carries the dashboard JSON. Panels:

1. **Cliques por minuto** — rate of `http_server_requests_total` on the redirect handler
2. **Latência p99** — histogram quantile on `http_request_duration_seconds`
3. **Taxa de erros** — ratio of 5xx responses
4. **Serviços saudáveis** — stat panel for pod readiness

---

## ArgoCD Application

```yaml
spec:
  source:
    repoURL: https://github.com/<org>/hackaton-portal-dos-links-gitops
    targetRevision: main
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

`prune: true` removes resources deleted from Git. `selfHeal: true` reverts manual kubectl changes. Together they enforce GitOps strictly.

---

## Secret Handling

Secrets are committed with **placeholder values** (`# REPLACE_ME`) for hackathon convenience. For a real environment the recommended upgrade path is:

1. Install **Sealed Secrets** controller in the cluster
2. Replace `Secret` manifests with `SealedSecret` CRDs encrypted with the cluster's public key
3. The plaintext never touches Git

---

## Ingress

A single `Ingress` in `k8s/frontend/ingress.yaml` with path-based routing:

| Path prefix | Backend service | Port |
|---|---|---|
| `/api` | `portal-api-svc` | `8080` |
| `/s` | `portal-api-svc` | `8080` |
| `/` (default) | `portal-frontend-svc` | `3000` |

Hostname is `portal.localdev` for local clusters (kind/minikube); override via Kustomize patch for staging/prod.

---

## CI Integration (from application repo)

The application repo's GitHub Actions workflow:

1. Builds and pushes Docker images tagged with the git SHA
2. Checks out **this** config repo
3. Runs `kustomize edit set image ghcr.io/<org>/portal-api:<sha>`
4. Opens a PR (or pushes directly to `main`) with the updated tag
5. ArgoCD picks up the change and deploys automatically
