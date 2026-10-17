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

### R1 — Kubernetes Manifests (per component) ⚠️ DONE WITH KNOWN DEFECTS

Each of the three components has a complete set of manifests inside `k8s/<component>/`. Several defects (G1–G10) are tracked in tasks T1, T2, T6, T7, T8.

- **R1.1** ✅ `Deployment` with:
  - Image tag sourced from Kustomize image override
  - Resource requests and limits set
  - Correct `livenessProbe` and `readinessProbe` (validated against running pods)
  - Environment variables injected from `ConfigMap` and/or `Secret` refs
- **R1.2** ✅ `Service` (ClusterIP) on correct port
- **R1.3** ✅ `ConfigMap` for non-sensitive config (API only)
  - ⚠️ Frontend has **no ConfigMap** — Vite bakes env vars at build time, runtime injection has no effect
- **R1.4** ✅ `Secret` for sensitive data — gitignored, applied manually via `kubectl apply`
  - API: `DATABASE_URL` as full connection string (see T1 — example file currently uses wrong key)
  - Database: `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`
- **R1.5** ✅ `PersistentVolumeClaim` for the database (1Gi ReadWriteOnce)
- **R1.6** ⏳ Deployments (API, Frontend) must **not** include `spec.replicas` when HPA is active — the HPA owns the replica count
- **R1.7** ⏳ API container (`portal-api`) must **not** define `command` or `args`; the image CMD (`node --import ./dist/tracing.js dist/main.js`) must run unmodified; overriding it silently disables tracing
- **R1.8** ⏳ API Deployment must carry `preStop` lifecycle hook (sleep 5 s) and `terminationGracePeriodSeconds: 30` to allow the Ingress to drain connections before the pod exits
- **R1.9** ⏳ All workloads must declare `topologySpreadConstraints` by node (`ScheduleAnyway`) and `rollingUpdate: {maxUnavailable: 0, maxSurge: 1}`
- **R1.10** ⏳ `startupProbe` on API to prevent premature liveness failures during cold-start / OTel initialization
- **R1.11** ⏳ `imagePullSecrets` for `ghcr-pull-secret` documented as optional overlay patch (not hardcoded in base manifest)

**Validated ports and probe paths (target state after T6):**

| Component | Port | Liveness | Readiness |
|---|---|---|---|
| API | 3000 | `GET /api/health` | `GET /api/ready` |
| Frontend | 80 | `GET /` | `GET /` |
| Database | 5432 | `pg_isready` exec | `pg_isready` exec |

### R2 — Kustomize Root ✅

- **R2.1** ✅ `k8s/kustomization.yaml` references `api`, `frontend`, `database`
- **R2.2** ✅ `images:` override block for both app images, currently pinned to SHA `5547b9d`
- **R2.3** ✅ `namespace: portal-dos-links` declared at root
- **R2.4** ⏳ `observability` commented out — enabled only after T3–T9 are verified (T12)

### R3 — ArgoCD Application ⚠️ DONE — needs updates for observability

- **R3.1** ✅ `argocd/application.yaml` defines ArgoCD `Application` pointing at `k8s/`
- **R3.2** ✅ Sync policy: automated, `prune: true`, `selfHeal: true`
- **R3.3** ✅ Destination: `https://kubernetes.default.svc`, namespace `portal-dos-links`
- **R3.4** ✅ `syncOptions: [CreateNamespace=true]`
- **R3.5** ⏳ `syncOptions` for the portal app must also include `SkipDryRunOnMissingResource=true` (so ServiceMonitor/PrometheusRule do not fail before CRDs are ready) and `ServerSideApply=true` (for large CRD objects)
- **R3.6** ⏳ A `retry` policy with exponential backoff must be set on the portal Application to handle transient CRD-not-ready failures on first observability sync

### R4 — Observability Stack ❌ BROKEN (exists but non-functional)

#### R4.1 — OTel Collector (`k8s/observability/`) ⏳

- **R4.1.1** ⏳ WHEN the Collector receives a span, THE SYSTEM SHALL export it to Tempo via OTLP gRPC (`tempo.observability.svc.cluster.local:4317`). *(Current config exports to `http://tempo:4318` — service does not exist)*
- **R4.1.2** ⏳ WHEN the Collector receives a metric, THE SYSTEM SHALL expose it via Prometheus exporter on port 8889 with `resource_to_telemetry_conversion` enabled (so `service.instance.id` becomes a Prometheus label)
- **R4.1.3** ⏳ WHEN memory usage exceeds 80% of the container limit, THE SYSTEM SHALL drop new telemetry data (`memory_limiter` processor) rather than be OOMKilled. *(Currently missing — retry queue grows unbounded)*
- **R4.1.4** ⏳ WHEN the Collector starts, THE SYSTEM SHALL expose a `health_check` extension on port 13133, used by liveness and readiness probes. *(Currently missing — probes are absent)*
- **R4.1.5** ⏳ WHEN the browser sends `POST /otlp/v1/traces`, THE SYSTEM SHALL route it to the Collector HTTP receiver on port 4318 via Ingress (`ingress-otlp.yaml`) without CORS overhead (same-origin path `/otlp`). *(Currently no HTTP receiver and no such Ingress)*
- **R4.1.6** ⏳ THE SYSTEM SHALL run 2 Collector replicas with HPA (CPU/memory), PDB `minAvailable: 1`, and rate-limit annotations on the OTLP Ingress (`limit-rps`, `proxy-body-size`)
- **R4.1.7** ⏳ THE SYSTEM SHALL expose Collector self-telemetry metrics on port 8888 and include them in a second `ServiceMonitor` target

#### R4.2 — Prometheus + Grafana + Tempo (`argocd/observability/`) ⏳

- **R4.2.1** ⏳ WHEN ArgoCD syncs, THE SYSTEM SHALL install `kube-prometheus-stack` (Helm, pinned version) in namespace `observability` via a dedicated ArgoCD Application, with `ServerSideApply=true` and sync-wave 0
- **R4.2.2** ⏳ WHEN ArgoCD syncs, THE SYSTEM SHALL install Grafana Tempo (Helm, single-binary, pinned version) in namespace `observability` via a separate ArgoCD Application
- **R4.2.3** ⏳ Prometheus MUST discover `ServiceMonitor` and `PrometheusRule` resources from **any** namespace (`serviceMonitorSelectorNilUsesHelmValues: false`)
- **R4.2.4** ⏳ Grafana sidecar MUST discover dashboards from **any** namespace (`searchNamespace: ALL`)
- **R4.2.5** ⏳ Tempo MUST be reachable at `tempo.observability.svc.cluster.local:4317` (gRPC) — the Collector exports to this address. **The chart Service name must be confirmed against `helm template` output before pinning** (do not assume)
- **R4.2.6** ⏳ Alertmanager and node-exporter MAY be disabled for local clusters; the values file MUST document the toggles to re-enable them in larger environments
- **R4.2.7** ⏳ Retention for Tempo and Prometheus MUST be set to 24–72 h for local clusters; PVC size must be declared and documented

#### R4.3 — API ConfigMap (`api-config`) ⏳

- **R4.3.1** ⏳ ConfigMap `api-config` MUST contain all required OTel env vars: `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317`, `OTEL_SERVICE_NAME=portal-dos-links-api`, `OTEL_TRACES_SAMPLER=parentbased_traceidratio`, `OTEL_TRACES_SAMPLER_ARG=0.1`, `OTEL_METRIC_EXPORT_INTERVAL=30000`, `OTEL_SEMCONV_STABILITY_OPT_IN=http`. *(Currently only OTEL_EXPORTER_OTLP_ENDPOINT is set)*
- **R4.3.2** ⏳ `POD_NAME`, `POD_NAMESPACE`, and `OTEL_RESOURCE_ATTRIBUTES=service.instance.id=$(POD_NAME),k8s.pod.name=$(POD_NAME),k8s.namespace.name=$(POD_NAMESPACE)` MUST be injected via downward API in the Deployment `env:` section (not the ConfigMap) so metrics from each replica carry a distinct `service.instance.id` label and counters do not collide
- **R4.3.3** ⏳ `PG_POOL_MAX=10` MUST be set in `api-config`; the constraint `maxReplicas × PG_POOL_MAX ≤ 80 % of max_connections` MUST be documented in the design (see D9)

#### R4.4 — Dashboard & Alerts ⏳

- **R4.4.1** ⏳ Dashboard panels MUST use metric names confirmed from `curl <collector-pod>:8889/metrics` output; placeholder names are invalid acceptance criteria
- **R4.4.2** ⏳ Rate windows in dashboard expressions and alert rules MUST be ≥ 4 × `OTEL_METRIC_EXPORT_INTERVAL` (≥ 2 min for 30 s interval)
- **R4.4.3** ⏳ `PrometheusRule` MUST define alerts for: 5xx rate > 2% for 5 min; p99 latency > 500 ms for 10 min; API/Frontend pods not ready; Collector export failures (`otelcol_exporter_send_failed_spans` / `otelcol_processor_refused_*` > 0); HPA at maximum replicas for 15 min
- **R4.4.4** ⏳ Dashboard datasource MUST be referenced by UID variable, not by the hardcoded string `"Prometheus"`
- **R4.4.5** ⏳ Root kustomization line `# - observability` MUST remain commented until T3–T9 pass CI validation (T12 uncomments it)

### R5 — Ingress / Networking ✅

Four separate Ingress objects, one per concern. The rewrite annotation in `ingress-redirect.yaml` applies only to that object; all other Ingresses are annotation-free.

- **R5.1** ✅ `ingress-api.yaml` — Prefix `/api` **without** `rewrite-target`, forwarded to `portal-api-svc:3000`
- **R5.2** ✅ `ingress-frontend.yaml` — Prefix `/` to `portal-frontend-svc:80`, no rewrite; static assets (`/assets/*`) pass through correctly
- **R5.3** ✅ `ingress-redirect.yaml` — regex `/s/(.*)` with `use-regex: "true"` and `rewrite-target: /$`1`; strips the `/s` prefix before forwarding to `portal-api-svc:3000`. The API serves `GET /:code` at the root and is not modified.
- **R5.4** ✅ `ingress-otlp.yaml` — Prefix `/otlp` to `otel-collector:4318`, no rewrite, with `limit-rps: 100` and `proxy-body-size: 1m`; the Collector matches `/otlp/v1/traces` via `traces_url_path` config
- **R5.5** ✅ WHEN a browser GETs `/s/<code>`, THE SYSTEM SHALL rewrite the path to `/<code>` and forward it to `portal-api-svc:3000`, which returns `302`.
- **R5.6** ✅ WHEN a browser POSTs to `/otlp/v1/traces`, THE SYSTEM SHALL forward the full path intact to the Collector HTTP receiver.

**Rejected alternative (M1 / D1 revision):** serve `GET /s/:code` natively in the API (no Ingress rewrite). Rejected because it requires modifying the application repo's route definitions, which is outside the scope of this GitOps repo.
### R6 — Repo Hygiene ✅

- **R6.1** ✅ `README.md` written — covers identity, structure, bootstrap, deploy, secret reference, troubleshooting, Kiro usage (observability section needs update — see T11)
- **R6.2** ✅ `**/secret.yaml` gitignored — secrets applied manually, never committed
- **R6.3** ✅ CI validates `kustomize build | kubeconform` on every push/PR (CRD catalog pending T10)
- **R6.4** ✅ Gitleaks scans for secrets on every push/PR
- **R6.5** ✅ `rendered.yaml` and `rendered-*.yaml` gitignored

### R7 — CI Validation Pipeline ⚠️ DONE WITH KNOWN DEFECTS

- **R7.1** ⏳ `.github/workflows/ci.yaml` must run on push to `main` **and `develop`** and PRs. *(Currently only main)*
- **R7.2** ✅ Gitleaks via `gitleaks/gitleaks-action@v2`
- **R7.3** ✅ kustomize 5.4.3 pinned install
- **R7.4** ⏳ `kubeconform -strict` with **CRD schema catalog** (`-schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'`) — `-ignore-missing-schemas` removed so ServiceMonitor/PrometheusRule/HPA are validated
- **R7.5** ⏳ Workflow must declare `permissions: contents: read`

### R8 — GitOps Automation ⏳

- **R8.1** ⏳ `CONFIG_REPO_PAT` secret must be created in the application repo (PAT with `contents: write` on this repo)
- **R8.2** ⏳ `yq` must be installed in the application repo's `update-manifests` job before the bump step
- **R8.3** ✅ `k8s/kustomization.yaml` uses `images:` block compatible with `yq` patching (`images[].newTag`)
- **R8.4** ⏳ Branch protection on `develop` must allow the bot push from the app CI pipeline

### R9 — Autoscaling e Alta Disponibilidade ⏳

- **R9.1** ⏳ WHEN CPU utilization of API pods exceeds 70%, THE SYSTEM SHALL scale out up to 6 replicas (HPA `autoscaling/v2`, min 2, `scaleDown.stabilizationWindowSeconds: 300`)
- **R9.2** ⏳ WHEN CPU utilization of Frontend pods exceeds 70%, THE SYSTEM SHALL scale out up to 4 replicas (HPA `autoscaling/v2`, min 2)
- **R9.3** ⏳ WHEN a node or pod is evicted, THE SYSTEM SHALL guarantee at least 1 API pod and 1 Frontend pod remain available (`PodDisruptionBudget minAvailable: 1`)
- **R9.4** ⏳ Cluster MUST have `metrics-server` installed (documented as prerequisite) for HPA to function
- **R9.5** ⏳ WHEN a rolling update is triggered, THE SYSTEM SHALL serve zero downtime (`maxUnavailable: 0`, `maxSurge: 1`, readiness gate via `GET /api/ready`)

### R10 — Migrações de Banco ⏳

- **R10.1** ⏳ WHEN a new version is deployed, THE SYSTEM SHALL run `prisma migrate deploy` exactly once per deploy (not once per new replica), using a Kubernetes `Job` with an ArgoCD `PreSync` hook
- **R10.2** ⏳ The migration Job MUST use the correct Prisma 7 config flag; the exact command MUST be validated against `kubectl logs` of the Job (do not assume the config filename)
- **R10.3** ⏳ The `initContainer` approach currently in the API Deployment MUST be removed once the Job is in place
