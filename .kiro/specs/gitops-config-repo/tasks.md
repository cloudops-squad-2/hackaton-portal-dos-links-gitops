# Tasks — GitOps Config Repo (Portal dos Links)

## Task 1 — Root Kustomization

Fill in `k8s/kustomization.yaml` with:
- `namespace: portal-dos-links`
- `resources:` listing `api`, `frontend`, `database`, `observability` directories
- `images:` override block for `portal-api` and `portal-frontend` with `newTag: latest`

**Acceptance:** `kustomize build k8s/` produces valid YAML with the namespace set on every resource.

---

## Task 2 — Database Manifests

Create the following files in `k8s/database/`:

- `secret.yaml` — `Secret` with keys `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` (placeholder values)
- `pvc.yaml` — `PersistentVolumeClaim` requesting 1Gi `ReadWriteOnce`
- `deployment.yaml` — `Deployment` for `postgres:16-alpine` mounting the PVC, injecting env from the Secret, with `pg_isready` liveness and readiness exec probes
- `service.yaml` — `ClusterIP` Service on port 5432

**Acceptance:** `kubectl apply --dry-run=client` on each file passes without errors.

---

## Task 3 — API Manifests

Create the following files in `k8s/api/`:

- `configmap.yaml` — `ConfigMap` with keys `OTEL_EXPORTER_OTLP_ENDPOINT` (`http://otel-collector:4317`) and `DATABASE_HOST` (`postgres-svc`)
- `secret.yaml` — `Secret` with key `DATABASE_PASSWORD` (placeholder)
- `deployment.yaml` — `Deployment` (2 replicas) injecting ConfigMap and Secret env refs, with `GET /healthz` liveness and `GET /readyz` readiness HTTP probes
- `service.yaml` — `ClusterIP` Service on port 8080

**Acceptance:** `kubectl apply --dry-run=client` on each file passes; ConfigMap keys match what the application repo expects.

---

## Task 4 — Frontend Manifests

Create the following files in `k8s/frontend/`:

- `configmap.yaml` — `ConfigMap` with key `NEXT_PUBLIC_API_URL` (e.g., `http://portal.localdev/api`)
- `deployment.yaml` — `Deployment` (2 replicas) injecting ConfigMap env refs, with HTTP probes on port 3000
- `service.yaml` — `ClusterIP` Service on port 3000
- `ingress.yaml` — `Ingress` with path-based routing (`/api` and `/s` → api service, `/` → frontend service)

**Acceptance:** `kubectl apply --dry-run=client` on each file passes; Ingress rules cover all required paths.

---

## Task 5 — Observability Manifests

Create `k8s/observability/kustomization.yaml` listing all resources, then:

- `otel-collector-configmap.yaml` — OTEL Collector config with OTLP gRPC receiver (4317), batch processor, Jaeger/Tempo and Prometheus exporters
- `otel-collector-deployment.yaml` — `Deployment` for `otel/opentelemetry-collector-contrib:latest` mounting the ConfigMap
- `otel-collector-service.yaml` — `Service` exposing ports 4317 (OTLP gRPC) and 8889 (Prometheus metrics)
- `grafana-dashboard-configmap.yaml` — `ConfigMap` labelled `grafana_dashboard: "1"` containing the pre-built dashboard JSON (panels: clicks/min, p99 latency, error rate, service health)

**Acceptance:** `kustomize build k8s/observability/` produces valid YAML; dashboard ConfigMap contains valid JSON.

---

## Task 6 — ArgoCD Application

Fill in `argocd/application.yaml` with:
- `repoURL` pointing to this repo
- `path: k8s`
- `targetRevision: main`
- Destination: `https://kubernetes.default.svc`, namespace `portal-dos-links`
- Sync policy: automated, `prune: true`, `selfHeal: true`, `syncOptions: [CreateNamespace=true]`

**Acceptance:** `kubectl apply --dry-run=client -f argocd/application.yaml` passes; ArgoCD can import the Application without validation errors.

---

## Task 7 — README

Write `README.md` covering:
1. Project identity — mascot name, one-paragraph story, and visual identity summary
2. Repo structure diagram
3. Prerequisites (kubectl, kustomize, argocd CLI)
4. Bootstrap steps: install ArgoCD → apply `argocd/application.yaml` → watch sync
5. How to trigger a new deploy (bump image tag)
6. Kiro usage log — key prompts used and decisions made with the AI copilot

**Acceptance:** README is accurate, readable, and includes a Kiro usage section as required by the hackathon rubric.
