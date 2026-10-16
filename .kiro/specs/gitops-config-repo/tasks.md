# Tasks — GitOps Config Repo (Portal dos Links)

## Task 1 — Root Kustomization ✅ DONE

`k8s/kustomization.yaml` with `namespace: portal-dos-links`, resources `api`, `frontend`, `database`, image overrides pinned to SHA `756c6d6`. Observability commented out pending Task 5.

---

## Task 2 — Database Manifests ✅ DONE

`k8s/database/` — `secret.yaml` (gitignored), `pvc.yaml` (1Gi), `deployment.yaml` (`postgres:16-alpine`, `pg_isready` probes), `service.yaml` (ClusterIP 5432), `kustomization.yaml`.

**Validated:** pod `1/1 Running` in cluster, 0 restarts.

---

## Task 3 — API Manifests ✅ DONE

`k8s/api/` — `configmap.yaml` (`OTEL_EXPORTER_OTLP_ENDPOINT` only), `secret.yaml` (`DATABASE_URL`, gitignored), `deployment.yaml` (2 replicas, port 3000, probes at `GET /api/health`), `service.yaml` (ClusterIP 3000), `kustomization.yaml`.

**Validated:** pods `1/1 Running` in cluster, probes passing, 0 restarts.

---

## Task 4 — Frontend Manifests ✅ DONE

`k8s/frontend/` — `deployment.yaml` (2 replicas, port 80 nginx, probes at `GET /`), `service.yaml` (ClusterIP 80), `ingress-api.yaml` (rewrite for `/api` + `/s`), `ingress-frontend.yaml` (plain prefix `/`), `kustomization.yaml`.

No ConfigMap — frontend is Vite, env vars are baked at build time.

**Validated:** pods `1/1 Running` in cluster, probes passing, 0 restarts.

**Fixes applied post-validation:**
- Split single Ingress into two — `rewrite-target` was breaking frontend static asset paths
- Fixed `containerPort` from 3000 to 80
- Removed dead ConfigMap and `envFrom`

---

## Task 5 — Observability Manifests ⏳ TODO

Create `k8s/observability/` with:

- `kustomization.yaml` — lists all resources
- `otel-collector-configmap.yaml` — OTEL Collector pipeline:
  - Receiver: OTLP gRPC (4317)
  - Processor: batch
  - Exporters: Jaeger/Tempo (traces) + Prometheus metrics (:8889)
- `otel-collector-deployment.yaml` — `otel/opentelemetry-collector-contrib:0.97.0`
- `otel-collector-service.yaml` — ports 4317 and 8889
- `grafana-dashboard-configmap.yaml` — labelled `grafana_dashboard: "1"`, dashboard JSON with panels: clicks/min, p99 latency, error rate, service health

After creating the directory, uncomment `observability` in `k8s/kustomization.yaml`.

**Acceptance:** `kustomize build k8s/` succeeds with observability included; dashboard JSON is valid.

---

## Task 6 — ArgoCD Application ✅ DONE

`argocd/application.yaml` — `targetRevision: develop`, `path: k8s`, automated sync with `prune: true` + `selfHeal: true` + `CreateNamespace=true`.

**Next:** verify sync is green after all changes are pushed to `develop`.

---

## Task 7 — CI Validation Pipeline ✅ DONE

`.github/workflows/ci.yaml` — Gitleaks + kustomize 5.4.3 + kubeconform strict. Runs on push to `main`/`develop` and PRs.

`.gitignore` — covers `**/secret.yaml`, `rendered.yaml`, `rendered-*.yaml`, binaries, OS noise.

---

## Task 8 — Merge to Develop and Verify ArgoCD Sync ⏳ IN PROGRESS

1. ✅ Merge all feature branches to `develop`
2. ⏳ Verify CI pipeline passes on `develop` (green check on GitHub Actions)
3. Apply secrets manually (gitignored — do this on every fresh cluster):
   ```bash
   kubectl create namespace portal-dos-links  # skip if exists
   kubectl apply -f k8s/database/secret.yaml
   kubectl apply -f k8s/api/secret.yaml
   ```
4. Apply the ArgoCD Application:
   ```bash
   kubectl apply -f argocd/application.yaml
   ```
5. Watch sync:
   ```bash
   kubectl get application -n argocd portal-dos-links -w
   ```
6. Verify all pods healthy:
   ```bash
   kubectl get pods -n portal-dos-links
   ```

**Acceptance:** ArgoCD shows `Synced` + `Healthy`; all 5 pods `1/1 Running`, 0 restarts.

---

## Task 9 — GitOps Automation Wiring ⏳ TODO

Complete the application repo → config repo handoff:

1. Create a GitHub PAT with `contents: write` scope on this repo
2. Add it as `CONFIG_REPO_PAT` secret in the **application repo**
3. Add `yq` install step to the application repo's `update-manifests` job:
   ```yaml
   - name: Install yq
     run: |
       curl -fsSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
         -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq
   ```
4. Verify `develop` branch protection allows the bot push (or disable required PRs for bot commits)
5. Trigger a test push on the application repo and confirm the tag bump lands on `develop` here

**Acceptance:** pushing to `develop` on the application repo automatically updates `newTag` in `k8s/kustomization.yaml` here, ArgoCD detects the diff and deploys the new image.

---

## Task 10 — README ✅ DONE

`README.md` covers: project identity, repo structure, prerequisites, bootstrap steps, deploy workflow, secret reference (aligned with actual secrets), troubleshooting (6 scenarios), Kiro usage log.

---

## Task 11 — CI Pipeline Hardening ⏳ TODO (good practice)

Non-blocking for the hackathon demo but worth doing:

- [ ] Pin `ubuntu-latest` to `ubuntu-24.04` in `ci.yaml`
- [ ] Add `permissions: contents: read` to the workflow
- [ ] Pin kubeconform download to a specific version with checksum verification
- [ ] Add branch protection on `develop` requiring `validate` job to pass before merge
- [ ] Add `rendered.yaml` to `.gitignore` and ensure it's untracked (`git rm --cached rendered.yaml`)
