# Requirements — GitOps Config Repo (Portal dos Links)

## Context

This repository is the **source of truth** for the Kubernetes cluster that runs the Portal dos Links hackathon project. It contains no application source code — only the infrastructure configuration that ArgoCD watches and reconciles against the cluster.

The application is a creative link-shortener with three runtime components:
- **frontend** — nginx serving a Vite static build, port 80
- **api** — NestJS shortening logic and redirect handler, port 3000
- **database** — PostgreSQL that maps short codes → original URLs, port 5432

Images are published to `ghcr.io/cloudops-squad-2/` by the application repo CI pipeline.

---

## Requirements

### R1 — Kubernetes Manifests (per component) ✅

Each of the three components has a complete set of manifests inside `k8s/<component>/`:

- **R1.1** ✅ `Deployment` with:
  - Image tag sourced from Kustomize image override
  - Resource requests and limits set
  - Correct `livenessProbe` and `readinessProbe` (validated against running pods)
  - Environment variables injected from `ConfigMap` and/or `Secret` refs
- **R1.2** ✅ `Service` (ClusterIP) on correct port
- **R1.3** ✅ `ConfigMap` for non-sensitive config (API only — `OTEL_EXPORTER_OTLP_ENDPOINT`)
  - ⚠️ Frontend has **no ConfigMap** — Vite bakes env vars at build time, runtime injection has no effect
- **R1.4** ✅ `Secret` for sensitive data — gitignored, applied manually via `kubectl apply`
  - API: `DATABASE_URL` as full connection string
  - Database: `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`
- **R1.5** ✅ `PersistentVolumeClaim` for the database (1Gi ReadWriteOnce)

**Validated ports and probe paths (confirmed against running pods):**

| Component | Port | Liveness | Readiness |
|---|---|---|---|
| API | 3000 | `GET /api/health` | `GET /api/health` |
| Frontend | 80 | `GET /` | `GET /` |
| Database | 5432 | `pg_isready` exec | `pg_isready` exec |

### R2 — Kustomize Root ✅

- **R2.1** ✅ `k8s/kustomization.yaml` references `api`, `frontend`, `database`
- **R2.2** ✅ `images:` override block for both app images, currently pinned to SHA `756c6d6`
- **R2.3** ✅ `namespace: portal-dos-links` declared at root
- **R2.4** ⏳ `observability` commented out — enabled after Task 5

### R3 — ArgoCD Application ✅

- **R3.1** ✅ `argocd/application.yaml` defines ArgoCD `Application` pointing at `k8s/`
- **R3.2** ✅ Sync policy: automated, `prune: true`, `selfHeal: true`
- **R3.3** ✅ Destination: `https://kubernetes.default.svc`, namespace `portal-dos-links`
- **R3.4** ✅ `syncOptions: [CreateNamespace=true]`
- **R3.5** ✅ `targetRevision: develop` — tracks `develop` branch; promote to `main` for releases

### R4 — Observability Stack ⏳

- **R4.1** ⏳ `k8s/observability/` directory with OTEL Collector and Grafana dashboard manifests
- **R4.2** ⏳ Root kustomization to include `observability` once ready
- **R4.3** ✅ OTEL endpoint already set in API ConfigMap — no changes needed when collector is deployed

### R5 — Ingress / Networking ✅

- **R5.1** ✅ Split Ingress design:
  - `ingress-api.yaml` — nginx rewrite for `/api` and `/s` paths to API service
  - `ingress-frontend.yaml` — plain prefix match for `/` to frontend service (no rewrite, preserves asset paths)
- **R5.2** ✅ Redirect endpoint (`GET /:code`) reachable via `/s/:code`
- **R5.3** ✅ Static assets (`/assets/*`) reach nginx correctly — not broken by rewrite

### R6 — Repo Hygiene ✅

- **R6.1** ✅ `README.md` written — covers identity, structure, bootstrap, deploy, secret reference, troubleshooting, Kiro usage
- **R6.2** ✅ `**/secret.yaml` gitignored — secrets applied manually, never committed
- **R6.3** ✅ CI validates `kustomize build | kubeconform` on every push/PR
- **R6.4** ✅ Gitleaks scans for secrets on every push/PR
- **R6.5** ✅ `rendered.yaml` and `rendered-*.yaml` gitignored

### R7 — CI Validation Pipeline ✅

- **R7.1** ✅ `.github/workflows/ci.yaml` runs on push to `main`/`develop` and PRs
- **R7.2** ✅ Gitleaks via `gitleaks/gitleaks-action@v2`
- **R7.3** ✅ kustomize 5.4.3 pinned install
- **R7.4** ✅ `kubeconform -strict -ignore-missing-schemas` validation

### R8 — GitOps Automation ⏳

- **R8.1** ⏳ `CONFIG_REPO_PAT` secret must be created in the application repo (PAT with `contents: write` on this repo)
- **R8.2** ⏳ `yq` must be installed in the application repo's `update-manifests` job before the bump step
- **R8.3** ✅ `k8s/kustomization.yaml` uses `images:` block compatible with `yq` patching
- **R8.4** ⏳ Branch protection on `develop` must allow the bot push from the app CI pipeline
