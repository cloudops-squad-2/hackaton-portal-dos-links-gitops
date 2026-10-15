# Requirements — GitOps Config Repo (Portal dos Links)

## Context

This repository is the **source of truth** for the Kubernetes cluster that runs the Portal dos Links hackathon project. It contains no application source code — only the infrastructure configuration that ArgoCD watches and reconciles against the cluster.

The application is a creative link-shortener with three runtime components:
- **frontend** — nginx serving a static build, port 80
- **api** — NestJS shortening logic and redirect handler, port 3000
- **database** — PostgreSQL that maps short codes → original URLs, port 5432

Images are published to `ghcr.io/cloudops-squad-2/` by the application repo CI pipeline.

---

## Requirements

### R1 — Kubernetes Manifests (per component) ✅

Each of the three components (`frontend`, `api`, `database`) has a complete set of Kubernetes manifests inside `k8s/<component>/`:

- **R1.1** ✅ `Deployment` with:
  - Image tag sourced from a `kustomize` image override
  - Resource requests and limits set
  - `livenessProbe` and `readinessProbe` configured with correct ports and paths
  - Environment variables injected from `ConfigMap` and `Secret` refs
- **R1.2** ✅ `Service` exposing the correct port(s)
- **R1.3** ✅ `ConfigMap` for non-sensitive configuration
- **R1.4** ✅ `Secret` for sensitive data — gitignored, applied manually via `kubectl apply`
- **R1.5** ✅ `PersistentVolumeClaim` for the database (1Gi ReadWriteOnce)

**Known ports (validated against running pods):**
- API: port `3000`, probes at `GET /api/health`
- Frontend: port `80`, probes at `GET /`
- Database: port `5432`, probes via `pg_isready`

### R2 — Kustomize Root ✅

- **R2.1** ✅ `k8s/kustomization.yaml` references `api`, `frontend`, `database` directories
- **R2.2** ✅ `images:` override block for both app images — tag pinned to current SHA `756c6d6`
- **R2.3** ✅ `namespace: portal-dos-links` declared at root
- **R2.4** ⏳ `observability` directory commented out — to be enabled after Task 5

### R3 — ArgoCD Application ✅

- **R3.1** ✅ `argocd/application.yaml` defines an ArgoCD `Application` pointing at `k8s/` path
- **R3.2** ✅ Sync policy: automated, `prune: true`, `selfHeal: true`
- **R3.3** ✅ Destination: `https://kubernetes.default.svc`, namespace `portal-dos-links`
- **R3.4** ✅ `syncOptions: [CreateNamespace=true]`
- **R3.5** ⚠️ Requires manifests to be on `main` branch — ArgoCD reads from Git, not local files

### R4 — Observability Stack Configuration ⏳

- **R4.1** ⏳ `k8s/observability/` directory with:
  - OpenTelemetry Collector (`Deployment` + `Service` + `ConfigMap`)
  - Grafana dashboard `ConfigMap`
- **R4.2** ⏳ Root kustomization to include `observability` once ready
- **R4.3** ✅ OTEL collector endpoint already set in API `ConfigMap` (`http://otel-collector:4317`)

### R5 — Ingress / Networking ✅

- **R5.1** ✅ nginx `Ingress` in `k8s/frontend/ingress.yaml` with path-based routing:
  - `/api` → `portal-api-svc:3000`
  - `/s` → `portal-api-svc:3000`
  - `/` → `portal-frontend-svc:80`
- **R5.2** ✅ Redirect endpoint (`GET /:code`) reachable via `/s` prefix

### R6 — Repo Hygiene

- **R6.1** ⏳ `README.md` not yet written
- **R6.2** ✅ `**/secret.yaml` gitignored — secrets applied manually, never committed
- **R6.3** ✅ CI pipeline validates `kustomize build | kubeconform` on every push/PR
- **R6.4** ✅ Gitleaks scans for accidentally committed secrets on every push/PR
- **R6.5** ⏳ `rendered.yaml` should be gitignored — currently present at repo root

### R7 — CI Validation Pipeline ✅

- **R7.1** ✅ `.github/workflows/ci.yaml` runs on push to `main`/`develop` and on PRs
- **R7.2** ✅ Gitleaks secret scanning
- **R7.3** ✅ `kustomize build k8s/` renders full manifest
- **R7.4** ✅ `kubeconform -strict` validates against Kubernetes schemas
