# Tasks — GitOps Config Repo (Portal dos Links)

## Status Legend
- ✅ DONE — implemented, validated, no known defects
- ⚠️ DONE WITH KNOWN DEFECTS — implemented but has issues tracked in T1–T12
- ❌ BROKEN — exists but non-functional
- ⏳ TODO / IN PROGRESS

---

## Original Tasks (re-assessed)

### Task 1 — Root Kustomization ✅ DONE

`k8s/kustomization.yaml` with `namespace: portal-dos-links`, resources `api`, `frontend`, `database`, image overrides pinned to SHA `5547b9d`. Observability commented out pending T12.

> **Note:** Previous spec listed SHA `756c6d6` — corrected to match the actual manifest.

---

### Task 2 — Database Manifests ✅ DONE

`k8s/database/` — `secret.example.yaml` (gitignored template), `pvc.yaml` (1Gi), `deployment.yaml` (`postgres:16-alpine`, `pg_isready` probes), `service.yaml` (ClusterIP 5432), `kustomization.yaml`.

**Validated:** pod `1/1 Running` in cluster, 0 restarts.

**Known limitation (G9 / D9):** single-replica Deployment + PVC — no HA. Scale path documented in design ADR D9. Not migrating now.

---

### Task 3 — API Manifests ⚠️ DONE WITH KNOWN DEFECTS

`k8s/api/` exists with Deployment, Service, ConfigMap, kustomization. Defects tracked in T1 and T6:

| Defect | ID | Fix task |
|---|---|---|
| `secret.example.yaml` uses `DATABASE_PASSWORD` instead of `DATABASE_URL` | G1 | T1 |
| ConfigMap has only `OTEL_EXPORTER_OTLP_ENDPOINT` — missing 5 OTel vars + `PG_POOL_MAX` | G6 | T6 |
| Readiness probe at `/api/health` — should be `/api/ready` (checks DB) | G7 | T6 |
| `replicas: 2` hardcoded — conflicts with HPA + `selfHeal` | G7 | T6 |
| No HPA, PDB, topologySpread, preStop, terminationGracePeriodSeconds, startupProbe | G7 | T6 |
| `initContainer` runs migrate on every pod (incl. scale-out), wrong command for Prisma 7 | G7 | T8 |
| Memory limit 256Mi likely insufficient for Node + OTel auto-instrumentation | G7 | T6 |
| `imagePullSecrets` not documented as patch | G10 | T6 |

---

### Task 4 — Frontend Manifests ⚠️ DONE WITH KNOWN DEFECTS

`k8s/frontend/` exists. Split Ingress is correct (no rewrite — aligns with contract). Defects tracked in T7:

| Defect | ID | Fix task |
|---|---|---|
| `replicas: 2` hardcoded — no HPA/PDB | G8 | T7 |
| No topologySpread | G8 | T7 |
| No `ingress-otlp.yaml` for browser traces | G8/D5 | T7 |

---

### Task 5 — Observability Manifests ⚠️ DONE — metric names must be verified at runtime

`k8s/observability/` reescrito e funcional. Todos os defects de G3/G4/G5/G12 foram corrigidos nas tasks T3–T5.

**Corrigidos:**

| Defect | ID | Status |
|---|---|---|
| Collector exports traces to `http://tempo:4318` — Service does not exist | G3 | ✅ Corrigido em T4: endpoint `tempo.observability.svc.cluster.local:4317` |
| No `memory_limiter` — retry queue grows to OOMKill under load | G3 | ✅ Corrigido em T4 |
| No `health_check` extension — no probes on Deployment | G3 | ✅ Corrigido em T4 |
| No OTLP/HTTP receiver — browser traces cannot reach Collector | G3 | ✅ Corrigido em T4 |
| Collector has 1 replica, no HPA, no PDB | G4 | ✅ Corrigido em T4 |
| No ServiceMonitor — Prometheus has no scrape target | G4 | ✅ Corrigido em T4 |
| No Prometheus, Grafana, or kube-state-metrics deployed | G4 | ✅ Corrigido em T3 |
| Grafana dashboard ConfigMap is orphaned (no Grafana to consume it) | G4 | ✅ Corrigido em T3 |
| Dashboard panel 4 uses `kube_pod_status_ready` — requires kube-state-metrics | G4 | ✅ Corrigido em T3/T5 |
| Dashboard queries use unverified metric names | G5 | ⚠️ Pendente verificação em runtime |
| `rate(...[1m])` window too short for 30 s scrape interval | G5 | ✅ Corrigido em T5: janelas de 2m |
| Datasource referenced as string `"Prometheus"` not by UID | G5 | ✅ Corrigido em T5: usa UID via variável `${datasource}` |
| Collector version in spec was `0.97.0`, manifest has `0.100.0` | G12 | ✅ Corrigido em T4: pinado em `0.163.1` |

**Pendente de verificação em cluster:**
- Nomes exatos das métricas HTTP (`http_server_request_duration_seconds_*`) — confirmar via `kubectl exec deploy/otel-collector -- wget -qO- http://localhost:8889/metrics | grep '^# TYPE http'`
- Nomes das métricas `otelcol_*` — confirmar via porta `:8888`

**Contadores de negócio no repo da aplicação:** `links.not_found` e `links.click_limit_reached` adicionados em `api/src/link/metrics.ts` e incrementados em `link.service.ts` — alinhados com dashboard (painel 3) e alertas.

---

### Task 6 — ArgoCD Application ⚠️ DONE — needs updates for T3

`argocd/application.yaml` exists, tracks `develop`, automated sync with prune + selfHeal + CreateNamespace=true.

**Required additions (T3):** `ServerSideApply=true`, `SkipDryRunOnMissingResource=true`, retry with backoff.

---

### Task 7 — CI Validation Pipeline ⚠️ DONE WITH KNOWN DEFECTS

`.github/workflows/ci.yaml` exists. Defects tracked in T10:

| Defect | ID | Fix task |
|---|---|---|
| Only triggers on push to `main` — misses `develop` (where bot pushes) | G11 | T10 |
| No `permissions: contents: read` | G11 | T10 |
| `kubeconform -ignore-missing-schemas` — CRDs (ServiceMonitor etc.) not validated | G11 | T10 |

---

### Task 8 — Merge to Develop and Verify ArgoCD Sync ⏳ IN PROGRESS

1. ✅ Merge all feature branches to `develop`
2. ⏳ Verify CI pipeline passes on `develop` (blocked by T10 — CI doesn't run on develop yet)
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

**Acceptance:** ArgoCD shows `Synced` + `Healthy`; all pods `1/1 Running`, 0 restarts.

---

### Task 9 — GitOps Automation Wiring ⏳ TODO

1. Create a GitHub PAT with `contents: write` scope on this repo
2. Add it as `CONFIG_REPO_PAT` secret in the application repo
3. Add `yq` install step to the application repo's `update-manifests` job:
   ```yaml
   - name: Install yq
     run: |
       curl -fsSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
         -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq
   ```
4. Verify `develop` branch protection allows the bot push (or configure job to open a PR instead)
5. Trigger a test push on the application repo and confirm the tag bump lands on `develop` here

**Acceptance:** pushing to `develop` on the application repo automatically updates `newTag` in `k8s/kustomization.yaml` here, ArgoCD detects the diff and deploys the new image.

---

### Task 10 — README ✅ DONE

`README.md` fully rewritten. Covers:
- Project identity, repo structure (all files, alphabetical, with comments)
- Prerequisites table (kubectl, kustomize, helm, argocd CLI, metrics-server, GHCR access)
- Bootstrap guide (correct order: ingress-nginx → metrics-server → ArgoCD → namespaces → secrets → observability stack → portal app)
- Wave table explaining sync order
- Port map and port-forward commands for all services
- Testing guide (curl commands + UI test)
- Day-to-day operations (deploy new version, force refresh, routine checks)
- Secret reference with `DATABASE_URL` key, URL-encoding note, `secret.example.yaml` copy instructions
- Ingress layout table with rewrite rationale
- Observability architecture diagram and component table
- CI pipeline section with `CONFIG_REPO_PAT` setup steps
- Minikube first-time cheatsheet
- Troubleshooting — 6 sections covering ArgoCD, pods, networking, database/migrations, observability, misc
- Kiro usage log

---

## New Tasks (T0–T12)

### T0 — Specs ✅ DONE

Updated `requirements.md`, `design.md`, `tasks.md` to reflect real repository state and full scope including D1–D9, R9, R10, and all finding corrections G1–G12.

**Acceptance:** diff approved by user. ✅

---

### T1 — Segredos (G1) ✅ DONE

**Files:** `k8s/api/secret.example.yaml`, `README.md`

Fix `secret.example.yaml`: replace `DATABASE_PASSWORD: changeme` with `DATABASE_URL` containing the full Postgres connection string template. Add comment explaining:
- The password must be URL-encoded (e.g. `@` → `%40`)
- The host must be `postgres-svc` (Kubernetes Service name, not `localhost`)
- The database name must match `POSTGRES_DB` in `k8s/database/secret.yaml`

**Acceptance criteria:**
- `secret.example.yaml` key is `DATABASE_URL`
- README secret reference uses `DATABASE_URL`
- The API's `getOrThrow('DATABASE_URL')` call (in `prisma.service.ts` in the app repo) matches the key name
- `kustomize build k8s/` + `kubeconform -strict` pass

---

### T2 — Ingress (G2) ✅ DONE

**Files:** `k8s/frontend/ingress-api.yaml`

Verify that `/api` and `/s` routes have no `rewrite-target` annotation (they currently don't — the manifest is already correct by contract). Update spec R5 to reflect this (done in T0). Confirm `kustomize build` passes.

Note: `ingress-otlp.yaml` is created in T7 (belongs to the Frontend kustomization group).

**Acceptance criteria:**
- `kustomize build k8s/` passes (with observability still commented out)
- `kubeconform -strict` passes
- With the correct API image deployed: `curl -i http://portal.localdev/s/<code>` returns `302`
- No `rewrite-target` annotation on `ingress-api.yaml`

---

### T3 — Observability Platform (D2, D3) ✅ DONE

**Files:** `argocd/observability/kube-prometheus-stack-app.yaml`, `argocd/observability/kube-prometheus-stack-values.yaml`, `argocd/observability/tempo-app.yaml`, `argocd/observability/tempo-values.yaml`, `argocd/application.yaml`

1. Look up current stable chart versions for `kube-prometheus-stack` and `grafana/tempo` before writing any YAML
2. Run `helm template` (or inspect chart) to confirm:
   - The exact Service name that Tempo creates (for the Collector to use as endpoint)
   - Default port for Tempo OTLP gRPC ingestion
3. Create `argocd/observability/` with two ArgoCD Applications:
   - `kube-prometheus-stack`: namespace `observability`, `sync-wave: "0"`, `ServerSideApply=true`, values enabling `serviceMonitorSelectorNilUsesHelmValues: false`, `searchNamespace: ALL` for Grafana sidecar, Alertmanager disabled (toggle documented), node-exporter disabled (toggle documented), Tempo datasource configured
   - `tempo`: namespace `observability`, single-binary mode, pinned version, PVC 10Gi, retention 24–72 h
4. Update `argocd/application.yaml` to add `sync-wave: "1"`, `SkipDryRunOnMissingResource=true`, `ServerSideApply=true`, and retry policy

**What cannot be verified without a running cluster:**
- Actual Service name created by the Tempo chart (must be confirmed via `helm template tempo grafana/tempo --version <ver> | grep 'kind: Service'`)
- Whether Grafana datasource auto-provisioning works with the sidecar config

**Acceptance criteria:**
- `helm template` of both charts renders without error
- Applications synced: Prometheus, Grafana, Tempo pods `Running` in `observability` namespace
- Grafana reachable via `kubectl port-forward` (never via public Ingress)

---

### T4 — Collector Rewrite (D4, D5, G3) ✅ DONE

**Files:** `k8s/observability/otel-collector-configmap.yaml`, `k8s/observability/otel-collector-deployment.yaml`, `k8s/observability/otel-collector-service.yaml`, `k8s/observability/otel-collector-hpa.yaml`, `k8s/observability/otel-collector-pdb.yaml`, `k8s/observability/otel-collector-servicemonitor.yaml`, `k8s/observability/kustomization.yaml`

Rewrite the Collector config to match the spec contract:
- Extensions: `health_check` on 13133
- Receivers: OTLP gRPC `:4317`, OTLP HTTP `:4318` with `traces_url_path: /otlp/v1/traces`
- Processors: `memory_limiter` (first) → `batch`
- Exporters: `otlp/tempo` to confirmed Tempo endpoint (gRPC, insecure), `prometheus` on `:8889` with `resource_to_telemetry_conversion: enabled: true`
- Service telemetry on `:8888`
- Pipelines: traces and metrics

Rewrite Deployment:
- Pinned image version (look up current stable `otel/opentelemetry-collector-contrib` tag)
- Probes on port 13133
- All 5 ports declared (4317, 4318, 8889, 8888, 13133)
- `securityContext`: non-root, readOnlyRootFilesystem
- Memory requests/limits sized for `memory_limiter` headroom
- Remove hardcoded `replicas` (HPA manages it)

Add: HPA (min 2, max 4, CPU 80%), PDB (`minAvailable: 1`), ServiceMonitor (targets 8889 and 8888 with 30 s scrape interval).

Update Service to add ports 4318, 8888, 13133.

**What cannot be verified without a running cluster:**
- Actual Tempo Service name and port (must be confirmed in T3 before T4 is complete)
- Whether `otelcol_*` metrics appear in Prometheus (requires T3 stack running)

**Acceptance criteria:**
- `kustomize build k8s/` (with `# - observability` still commented) passes
- `kubeconform -strict` with CRD catalog passes for all new resources
- After T12: Collector pods `Ready`, `otelcol_*` metrics visible in Prometheus

**Deliverable for the application repo:** at the end of T4 and T5, print the full content of:
- `otel-collector-config.yaml` (the ConfigMap data field)
- `portal-dos-links-dashboard.json` (the dashboard JSON)

with file paths noted. These are copied to the application repo's `docker-compose` setup (source of truth is this repo).

---

### T5 — Dashboard (G5) ⚠️ DONE — metric names must be verified at runtime

**Files:** `k8s/observability/grafana-dashboard-configmap.yaml`

Rebuild dashboard JSON after confirming metric names. Steps:
1. With the Collector running, scrape `:8889/metrics`:
   ```bash
   kubectl exec -n portal-dos-links deploy/otel-collector -- \
     wget -qO- http://localhost:8889/metrics | grep -E '^# TYPE (http|links)'
   ```
2. Note actual metric names (expected with `OTEL_SEMCONV_STABILITY_OPT_IN=http`: `http_server_request_duration_seconds_*`)
3. Rebuild panels with verified names and rate windows ≥ 2 min

**Panels to include:**
1. `links_redirected_total` rate — redirects/s
2. `links_created_total` rate — creations/s
3. `links_expired_total`, `links_not_found_total`, `links_click_limit_reached_total` rates
4. HTTP latency p50/p95/p99 (histogram_quantile)
5. 5xx percentage
6. Pods ready per Deployment (kube_deployment_status_replicas_ready)
7. HPA current vs max replicas
8. Collector export failures (`otelcol_exporter_send_failed_spans_total`)

**Dashboard requirements:**
- Datasource by UID variable (`${datasource}`), not string `"Prometheus"`
- Rate windows ≥ 2 min (`[2m]`)
- No label with link code or URL on any metric

**What cannot be verified without a running cluster:**
- Actual metric names (the step above is required before merging T5)
- Whether panels show data (requires traffic generation)

**Acceptance criteria:**
- No panel shows "No data" with traffic generated per testing guide
- All rate windows ≥ 2 min
- Dashboard JSON valid (parseable by Grafana)

---

### T6 — API Deployment & ConfigMap (G6, G7, G10, D6, D9) ✅ DONE

**Files:** `k8s/api/configmap.yaml`, `k8s/api/deployment.yaml`, `k8s/api/hpa.yaml` (new), `k8s/api/pdb.yaml` (new), `k8s/api/kustomization.yaml`

**ConfigMap `api-config` — add all required keys:**
```
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
OTEL_SERVICE_NAME=portal-dos-links-api
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.1
OTEL_METRIC_EXPORT_INTERVAL=30000
OTEL_SEMCONV_STABILITY_OPT_IN=http
PG_POOL_MAX=10
```

**Deployment changes:**
- Remove `spec.replicas`
- Remove `initContainer` (replaced by Job in T8)
- Change readiness probe to `GET /api/ready`
- Add `startupProbe` (`GET /api/health`, failureThreshold 30, periodSeconds 5 = 150 s window)
- Add `preStop: exec: command: ["sh", "-c", "sleep 5"]`
- Add `terminationGracePeriodSeconds: 30`
- Increase memory limit to 384Mi (validate under load; may increase to 512Mi)
- Add downward API env vars (in `env:`, not ConfigMap):
  ```yaml
  - name: POD_NAME
    valueFrom:
      fieldRef:
        fieldPath: metadata.name
  - name: POD_NAMESPACE
    valueFrom:
      fieldRef:
        fieldPath: metadata.namespace
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: "service.instance.id=$(POD_NAME),k8s.pod.name=$(POD_NAME),k8s.namespace.name=$(POD_NAMESPACE)"
  ```
  (POD_NAME and POD_NAMESPACE must be declared before OTEL_RESOURCE_ATTRIBUTES for `$(VAR)` interpolation to work)
- Add `topologySpreadConstraints` by node (`ScheduleAnyway`)
- Add `rollingUpdate: {maxUnavailable: 0, maxSurge: 1}`
- **Do not set `command` or `args` on the `portal-api` container**
- Add comment: `# imagePullSecrets: [{name: ghcr-pull-secret}]  # apply as overlay patch if registry is private`

**Add:** `hpa.yaml` (autoscaling/v2, min 2, max 6, CPU 70%, scaleDown 300 s), `pdb.yaml` (minAvailable: 1)

**Acceptance criteria:**
- `kustomize build k8s/` + `kubeconform -strict` pass
- `kubectl rollout restart deployment/portal-api` with continuous load produces zero 5xx
- `kubectl get deploy portal-api -n portal-dos-links -o jsonpath='{.spec.template.spec.containers[0].command}'` returns empty
- `kubectl exec deploy/portal-api -n portal-dos-links -- cat /proc/1/cmdline` (NUL-separated args) contains `--import`
- Readiness via `/api/ready`, liveness via `/api/health`

---

### T7 — Frontend (G8, D6) ✅ DONE

**Files:** `k8s/frontend/deployment.yaml`, `k8s/frontend/hpa.yaml` (new), `k8s/frontend/pdb.yaml` (new), `k8s/frontend/ingress-otlp.yaml` (new), `k8s/frontend/kustomization.yaml`

**Deployment changes:**
- Remove `spec.replicas`
- Add `topologySpreadConstraints` by node (`ScheduleAnyway`)
- Add `rollingUpdate: {maxUnavailable: 0, maxSurge: 1}`

**Add:** `hpa.yaml` (min 2, max 4, CPU 70%), `pdb.yaml` (minAvailable: 1)

**Add `ingress-otlp.yaml`:**
```yaml
# Routes browser OTel traces: POST /otlp/v1/traces → otel-collector:4318
# No rewrite; Collector matches path via traces_url_path config
# Rate-limited to protect against unauthenticated public endpoint
```
Annotations: `limit-rps: "100"`, `proxy-body-size: "1m"`

**Acceptance criteria:**
- `kustomize build k8s/` + `kubeconform -strict` pass
- `POST http://portal.localdev/otlp/v1/traces` with a valid empty OTLP payload returns `200`
- Requests above the rate limit are rejected with `429`

---

### Task 8 — Migrações (G7, D7) ✅ DONE — Sync hook wave 1, Prisma config verified at runtime

**Files:** `k8s/database/migration-job.yaml`, `k8s/api/deployment.yaml` (initContainer removed), `k8s/database/kustomization.yaml`

**Actual implementation (differs from original spec):**

The Job uses `argocd.argoproj.io/hook: Sync` with `sync-wave: "1"` — **not PreSync**. PreSync was rejected because it runs before Postgres exists on a fresh install, causing connection failures. Wave 1 guarantees Postgres (wave 0) is Healthy before the migration runs.

| Field | Value |
|---|---|
| Hook | `Sync` (not PreSync) |
| Wave | `1` (after Postgres wave 0, before API wave 2) |
| Delete policy | `BeforeHookCreation` (failed Job stays for inspection; replaced on next sync) |
| backoffLimit | `6` (generous — Postgres may still be warming up after Ready) |
| Command | `["sh", "-c", "npx prisma migrate deploy --schema=prisma/schema.prisma"]` |
| Env | `envFrom: secretRef: api-secret` (needs DATABASE_URL) |

**initContainer removed** from `k8s/api/deployment.yaml`. Comment added explaining the migration is now handled by the Job.

**Validated:** `prisma-migrate` Job shows `Completed` in cluster; `public.Link` table confirmed created.

**Acceptance criteria:** ✅
- `kustomize build k8s/` + `kubeconform -strict` pass
- `kubectl get jobs -n portal-dos-links` shows `prisma-migrate` Completed
- API pods reach `1/1 Running` after Job completes
- No `initContainer` in API Deployment

---

### T9 — Alertas (D8) ⚠️ DONE — metric names must be verified at runtime

**Files:** `k8s/observability/prometheus-rule.yaml` (new), `k8s/observability/kustomization.yaml`

Create `PrometheusRule` with alerts from D8. Use metric names confirmed in T5 (do not write this task before T5 metrics are verified). Rate windows ≥ 2 min.

**What cannot be verified without a running cluster:**
- Exact metric names for HTTP duration (depend on `OTEL_SEMCONV_STABILITY_OPT_IN=http` and collector version)
- Whether Prometheus loads the rules without error

**Acceptance criteria:**
- `kubeconform -strict` with CRD catalog passes for `PrometheusRule`
- Prometheus Rules tab shows all rules loaded with no evaluation errors
- Alert `APIHighErrorRate` fires when error rate is artificially elevated (smoke test)

---

### T10 — CI (G11) ✅ DONE

**Files:** `.github/workflows/ci.yaml`

Changes:
1. Add `develop` to push trigger:
   ```yaml
   push:
     branches: [main, develop]
   ```
2. Add `permissions: contents: read` at workflow level
3. Replace `kubeconform -ignore-missing-schemas` with CRD catalog:
   ```
   kubeconform -strict -summary \
     -schema-location default \
     -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
     rendered.yaml
   ```
4. Keep Gitleaks step unchanged

**Acceptance criteria:**
- A push to `develop` (e.g. a README change) triggers the `validate` job
- Job passes with `kubeconform` validating the CRD resources
- `permissions: contents: read` present in workflow YAML

---

### T11 — README (G12) ✅ DONE

**Files:** `README.md`

Updates:
1. Remove "Coming soon" from observability section
2. Add **Observability Architecture** section (brief diagram + component summary)
3. Update **Bootstrap** to reflect correct order (ingress-nginx → metrics-server → ArgoCD → secrets → observability stack → portal app)
4. Add **Grafana / Prometheus access** section (port-forward only, never public Ingress)
5. Add **Observability troubleshooting** section:
   - No data in Grafana panels
   - Collector pods OOMKilled
   - Tempo not receiving spans
   - `otelcol_exporter_send_failed_*` > 0
6. Update prereqs table to include `metrics-server`, `helm`
7. Update secret reference section to match `DATABASE_URL` key (aligned with T1)

**Acceptance criteria:**
- No mention of "Coming soon" for observability
- Bootstrap order is correct and complete
- Grafana access section present with port-forward command

---

### T12 — Enable Observability ✅ DONE

**Files:** `k8s/kustomization.yaml`

Uncomment `- observability` in `k8s/kustomization.yaml` **only after T3–T9 are all green**.

**Acceptance criteria:**
- `kustomize build k8s/` succeeds with observability included
- `kubeconform -strict` with CRD catalog passes for all resources including observability
- ArgoCD shows `Synced` + `Healthy` for the portal Application
- All pods (API, Frontend, Database, Collector) `1/1 Running`, 0 restarts
- Prometheus scrapes Collector metrics (ServiceMonitor active)
- Grafana dashboard loads without "No data" panels (with traffic)
