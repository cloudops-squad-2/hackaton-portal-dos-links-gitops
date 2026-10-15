# Tasks — GitOps Config Repo (Portal dos Links)

## Task 1 — Root Kustomization ✅ DONE

`k8s/kustomization.yaml` created with:
- `namespace: portal-dos-links`
- `resources:` listing `api`, `frontend`, `database` (observability commented out pending Task 5)
- `images:` override block for both app images pinned to SHA `756c6d6`

---

## Task 2 — Database Manifests ✅ DONE

`k8s/database/` contains:
- `secret.yaml` — gitignored, applied manually with `kubectl apply`
- `pvc.yaml` — 1Gi ReadWriteOnce
- `deployment.yaml` — `postgres:16-alpine`, `pg_isready` probes, PVC mounted
- `service.yaml` — ClusterIP on port 5432
- `kustomization.yaml` — directory manifest

**Validated:** pod running `1/1` in cluster.

---

## Task 3 — API Manifests ✅ DONE

`k8s/api/` contains:
- `configmap.yaml` — `OTEL_EXPORTER_OTLP_ENDPOINT` only (non-sensitive)
- `secret.yaml` — `DATABASE_URL` as full connection string (gitignored, applied manually)
- `deployment.yaml` — 2 replicas, port 3000, probes at `GET /api/health`
- `service.yaml` — ClusterIP on port 3000
- `kustomization.yaml` — directory manifest

**Validated:** pods running `1/1` in cluster, probes passing.

---

## Task 4 — Frontend Manifests ✅ DONE

`k8s/frontend/` contains:
- `configmap.yaml` — `NEXT_PUBLIC_API_URL`
- `deployment.yaml` — 2 replicas, port 80 (nginx), probes at `GET /`
- `service.yaml` — ClusterIP on port 80
- `ingress.yaml` — nginx Ingress: `/api` + `/s` → api, `/` → frontend
- `kustomization.yaml` — directory manifest

**Validated:** pods running `1/1` in cluster, probes passing.

---

## Task 5 — Observability Manifests ⏳ TODO

Create `k8s/observability/` with:

- `kustomization.yaml` — lists all resources in the directory
- `otel-collector-configmap.yaml` — OTEL Collector pipeline config:
  - Receiver: OTLP gRPC (4317)
  - Processor: batch
  - Exporters: Jaeger/Tempo (traces) + Prometheus (metrics on :8889)
- `otel-collector-deployment.yaml` — `otel/opentelemetry-collector-contrib:0.97.0`
- `otel-collector-service.yaml` — ports 4317 (OTLP gRPC) and 8889 (Prometheus metrics)
- `grafana-dashboard-configmap.yaml` — pre-built dashboard JSON with panels:
  - Clicks per minute (rate of redirect requests)
  - p99 latency (histogram quantile)
  - Error rate (5xx ratio)
  - Service health (pod readiness stat panel)

After creating the directory, uncomment `observability` in `k8s/kustomization.yaml`.

**Acceptance:** `kustomize build k8s/` succeeds with observability included; dashboard JSON is valid.

---

## Task 6 — ArgoCD Application ✅ DONE

`argocd/application.yaml` created with:
- `repoURL: https://github.com/cloudops-squad-2/hackaton-portal-dos-links-gitops.git`
- `path: k8s`, `targetRevision: main`
- Destination: `https://kubernetes.default.svc`, namespace `portal-dos-links`
- Sync policy: automated, `prune: true`, `selfHeal: true`, `CreateNamespace=true`

**Next step:** merge all changes to `main` so ArgoCD can sync from Git.

---

## Task 7 — CI Validation Pipeline ✅ DONE

`.github/workflows/ci.yaml` created with:
- Gitleaks secret scanning
- kustomize 5.4.3 install
- kubeconform strict validation
- Runs on push to `main`/`develop` and PRs

`.gitignore` covers secrets (`**/secret.yaml`), build artifacts (`rendered.yaml`), binaries and OS noise.

---

## Task 8 — Merge to Main and Verify ArgoCD Sync ⏳ TODO

1. Merge all open PRs / push pending commits to `main`
2. Verify CI pipeline passes (green check on GitHub Actions)
3. Apply secrets manually (they are gitignored):
   ```bash
   kubectl create namespace portal-dos-links  # if not exists
   kubectl apply -f k8s/api/secret.yaml
   kubectl apply -f k8s/database/secret.yaml
   ```
4. Apply the ArgoCD Application:
   ```bash
   kubectl apply -f argocd/application.yaml
   ```
5. Watch ArgoCD sync:
   ```bash
   kubectl get application -n argocd portal-dos-links -w
   ```
6. Verify all pods reach `1/1 Running`:
   ```bash
   kubectl get pods -n portal-dos-links
   ```

**Acceptance:** ArgoCD shows `Synced` + `Healthy`; all 5 pods running with 0 restarts.

---

## Task 9 — README ⏳ TODO

Write `README.md` at repo root covering:
1. Project identity — mascot name, one-paragraph story, visual identity summary
2. Repo structure diagram
3. Prerequisites: `kubectl`, `kustomize`, `argocd` CLI
4. Bootstrap steps: install ArgoCD → apply secrets → apply `argocd/application.yaml` → watch sync
5. How to trigger a new deploy (bump image tag in `k8s/kustomization.yaml`)
6. Kiro usage log — key prompts and decisions made with the AI copilot

**Acceptance:** README is accurate and includes the Kiro usage section (required by hackathon rubric).
