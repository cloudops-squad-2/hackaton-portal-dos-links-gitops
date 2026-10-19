# Design — GitOps Config Repo (Portal dos Links)
## Inter-Repository Contract

This table defines the interface between this GitOps repo and the application repo. Neither side may change these values unilaterally.

| Item | Value |
|---|---|
| Redirect public URL | `/s/:code` — the `/s` prefix is stripped by `ingress-redirect.yaml` (rewrite `/\`) before reaching the API |
| API route for redirect | `GET /:code` at the root — **not modified** in the application repo |
| API container command | Deployment does **not** define `command` or `args`; the image CMD (`node --import ./dist/tracing.js dist/main.js`) runs as-is |
| OTel endpoint | `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317` |
| OTel service name | `OTEL_SERVICE_NAME=portal-dos-links-api` |
| OTel sampler | `OTEL_TRACES_SAMPLER=parentbased_traceidratio`, `ARG=0.1` |
| Metric export interval | `OTEL_METRIC_EXPORT_INTERVAL=30000` (ms); rate windows in dashboard and alerts must be ≥ 4× this value (≥ 2 min) |
| HTTP semconv | `OTEL_SEMCONV_STABILITY_OPT_IN=http` — identical in cluster (ConfigMap) and in app repo docker-compose |
| Custom metric names | `links.created`, `links.redirected`, `links.expired`, `links.not_found`, `links.click_limit_reached` → Prometheus: `links_*_total` |
| Metric labels | **No** label with link code or URL on any metric |
| Dashboard/alert route filter | `http.route="/:code"` — **not** `/s/.*` (because the API never sees `/s`) |
| Browser trace path | `POST /otlp/v1/traces` forwarded by `ingress-otlp.yaml` to Collector `:4318`; no rewrite; Collector `traces_url_path: /otlp/v1/traces` |
| API secret key | `DATABASE_URL` (full Postgres connection string, URL-encoded password) |
| Pool constraint | `maxReplicas (6) × PG_POOL_MAX (10) = 60 ≤ 80% × 100 = 80` |
| Observability source of truth | This repo (`k8s/observability/`); the app repo docker-compose copies `otel-collector-config.yaml` and the dashboard JSON with a header comment indicating the origin commit |

---


## Repository Layout

```
hackaton-portal-dos-links-gitops/
├── argocd/
│   ├── application.yaml                    # ArgoCD Application — portal-dos-links
│   └── observability/                      # (new — T3)
│       ├── kube-prometheus-stack-app.yaml
│       ├── kube-prometheus-stack-values.yaml
│       ├── tempo-app.yaml
│       └── tempo-values.yaml
├── k8s/
│   ├── kustomization.yaml                  # Root — namespace, resources, image tag overrides
│   ├── api/
│   │   ├── configmap.yaml                  # OTel + pool config (expanded in T6)
│   │   ├── secret.example.yaml             # DATABASE_URL template (fixed in T1)
│   │   ├── deployment.yaml                 # (updated in T6 and T8)
│   │   ├── service.yaml
│   │   ├── hpa.yaml                        # (new — T6)
│   │   ├── pdb.yaml                        # (new — T6)
│   │   └── kustomization.yaml
│   ├── frontend/
│   │   ├── deployment.yaml                 # (updated in T7)
│   │   ├── service.yaml
│   │   ├── ingress-api.yaml                # /api only — no rewrite (M1)
│   │   ├── ingress-frontend.yaml           # / — no rewrite
│   │   ├── ingress-redirect.yaml           # /s/(.*) → rewrite /$1 → portal-api-svc (M1)
│   │   ├── ingress-otlp.yaml               # /otlp → otel-collector:4318 (new — T7)
│   │   ├── hpa.yaml                        # (new — T7)
│   │   ├── pdb.yaml                        # (new — T7)
│   │   └── kustomization.yaml
│   ├── database/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── secret.example.yaml
│   │   ├── pvc.yaml
│   │   ├── migration-job.yaml              # (new — T8, ArgoCD PreSync hook)
│   │   └── kustomization.yaml
│   └── observability/                      # Kustomize, namespace portal-dos-links
│       ├── kustomization.yaml
│       ├── otel-collector-configmap.yaml   # (rewritten — T4)
│       ├── otel-collector-deployment.yaml  # (rewritten — T4)
│       ├── otel-collector-service.yaml     # (updated — T4)
│       ├── otel-collector-hpa.yaml         # (new — T4)
│       ├── otel-collector-pdb.yaml         # (new — T4)
│       ├── otel-collector-servicemonitor.yaml  # (new — T4)
│       ├── prometheus-rule.yaml            # (new — T9)
│       └── grafana-dashboard-configmap.yaml    # (rebuilt — T5)
├── .github/
│   └── workflows/
│       └── ci.yaml                         # (updated — T10)
├── .gitignore
└── README.md                               # (updated — T11)
```

---

## Namespace Strategy

| Namespace | Contents |
|---|---|
| `portal-dos-links` | API, Frontend, Database, OTel Collector, Grafana dashboard ConfigMap |
| `observability` | kube-prometheus-stack (Prometheus, Grafana, kube-state-metrics), Tempo |
| `argocd` | ArgoCD itself |

The ArgoCD Application for the portal carries `CreateNamespace=true`. The observability Applications also carry `CreateNamespace=true`. Secrets are gitignored and applied manually before first sync.

---

## Telemetry Flow

```
Browser ──POST /otlp/v1/traces──► Ingress (ingress-otlp.yaml, /otlp Prefix)
                                      │ no rewrite; Collector matches via traces_url_path
                                      ▼ :4318 HTTP
                              ┌─────────────────────────────────┐
API pods ──OTLP gRPC:4317────►│  OTel Collector                 │
                              │  (portal-dos-links ns, 2 reps)  │
                              │  memory_limiter → batch         │
                              └──────────┬──────────────────────┘
                                         │
                        ┌────────────────┴────────────────────┐
                        ▼                                     ▼
              otlp/tempo:4317                        prometheus :8889
         tempo.observability                         ServiceMonitor
         .svc.cluster.local                               │
         (observability ns)                               ▼
                                                    Prometheus
                                                (kube-prometheus-stack)
                                                          │
                                                          ▼
                                                       Grafana
                                               (dashboard ConfigMap via
                                                sidecar, searchNamespace: ALL)
```

---

## Kustomize Image Override Pattern

The root `k8s/kustomization.yaml` declares:

```yaml
images:
  - name: ghcr.io/cloudops-squad-2/portal-dos-links-api
    newTag: "5547b9d"   # application repo CI bumps this with the git SHA
  - name: ghcr.io/cloudops-squad-2/portal-dos-links-frontend
    newTag: "5547b9d"
```

The application repo's `update-manifests` job uses `yq` to patch `newTag` and pushes directly to `develop`. ArgoCD detects the change and reconciles automatically. **This block must never be modified by this spec's tasks.**

---

## Component Design

### API

| Field | Value |
|---|---|
| Image | `ghcr.io/cloudops-squad-2/portal-dos-links-api` |
| Port | `3000` (NestJS default) |
| Replicas | Managed by HPA (min 2, max 6) — `spec.replicas` removed |
| Liveness | `GET /api/health` port 3000 |
| Readiness | `GET /api/ready` port 3000 (checks database) |
| Startup | `startupProbe` to cover cold-start / OTel init |
| Env (ConfigMap) | See R4.3.1 — full OTel config + `PG_POOL_MAX=10` |
| Env (Downward API) | `POD_NAME`, `POD_NAMESPACE`, `OTEL_RESOURCE_ATTRIBUTES` — in Deployment `env:` only |
| Env (Secret) | `DATABASE_URL=postgres://portal:<pw-url-encoded>@postgres-svc:5432/portal` |
| command / args | **Not set** — the image CMD (`node --import ./dist/tracing.js dist/main.js`) runs as-is |
| preStop | `sleep 5` — allows Ingress to drain before pod exits |
| terminationGracePeriodSeconds | `30` |
| Memory limit | 384–512 Mi (to be validated under load with OTel auto-instrumentation) |

The API Service is `ClusterIP` on port 3000.

### Frontend

| Field | Value |
|---|---|
| Image | `ghcr.io/cloudops-squad-2/portal-dos-links-frontend` |
| Port | `80` (nginx serving Vite static build) |
| Replicas | Managed by HPA (min 2, max 4) — `spec.replicas` removed |
| Liveness | `GET /` port 80 |
| Readiness | `GET /` port 80 |
| Env | None — Vite bakes env vars at build time |

No ConfigMap. The frontend Service is `ClusterIP` on port 80.

### Database (PostgreSQL)

| Field | Value |
|---|---|
| Image | `postgres:16-alpine` |
| Port | `5432` |
| Replicas | `1` (Deployment + PVC — single-replica by design; see D9) |
| Liveness | `pg_isready -U $(POSTGRES_USER) -d $(POSTGRES_DB)` exec probe |
| Readiness | `pg_isready -U $(POSTGRES_USER) -d $(POSTGRES_DB)` exec probe |
| Storage | `PersistentVolumeClaim` 1Gi, `ReadWriteOnce` |
| Env (Secret) | `POSTGRES_USER=portal`, `POSTGRES_PASSWORD=<pw>`, `POSTGRES_DB=portal` |

The database Service is `ClusterIP` — never exposed outside the cluster. The `POSTGRES_DB` value must match the database name in the API's `DATABASE_URL`.

### OTel Collector

| Field | Value |
|---|---|
| Image | `otel/opentelemetry-collector-contrib` (pinned version — T4) |
| Replicas | Managed by HPA (min 2) — `spec.replicas` removed |
| Ports | 4317 (OTLP gRPC), 4318 (OTLP HTTP), 8889 (Prometheus exporter), 8888 (self-telemetry), 13133 (health_check) |
| Liveness | `GET /` port 13133 (health_check extension) |
| Readiness | `GET /` port 13133 |

---

## Ingress Design

Four Ingress objects, all in `k8s/frontend/`. Each concern has its own object because the nginx `rewrite-target` annotation applies to the entire Ingress — mixing rewrite and non-rewrite paths on the same object would cause unintended path stripping.

### `ingress-api.yaml` — no rewrite

`
/api (Prefix) → portal-api-svc:3000  (path forwarded as-is)
`

No annotation. `/api/links`, `/api/health`, `/api/ready` all pass through unmodified.

### `ingress-redirect.yaml` — regex rewrite (M1 decision)

`
/s/(.*) (ImplementationSpecific) → portal-api-svc:3000  (rewritten to /)
`

Annotations:
`yaml
nginx.ingress.kubernetes.io/use-regex: "true"
nginx.ingress.kubernetes.io/rewrite-target: /
`

Strips the `/s` prefix so the API receives `GET /<code>` at the root. The API is not modified.

**Why separate from ingress-api.yaml:** the `rewrite-target` annotation affects every path in an Ingress. If `/api` were in the same object, requests to `/api/links` would be rewritten to `/links`, breaking the API.

### `ingress-frontend.yaml` — no rewrite

`
/ (Prefix) → portal-frontend-svc:80
`

No annotation. `/assets/app.js` and all static assets pass through correctly.

### `ingress-otlp.yaml` — no rewrite, with rate limiting

`
/otlp (Prefix) → otel-collector:4318  (Collector matches /otlp/v1/traces via traces_url_path config)
`

Annotations:
`yaml
nginx.ingress.kubernetes.io/limit-rps: "100"
nginx.ingress.kubernetes.io/proxy-body-size: "1m"
`

Hostname: `portal.localdev` for local clusters on all four Ingresses.

---
## Architecture Decision Records

### D1 — Redirect Path: Ingress sem rewrite

**Decision:** `/s` Prefix without `rewrite-target`. The API serves `GET /s/:code` natively — the full path reaches the API unchanged.

**Rejected alternative:** rewrite `/$2` with path regex `/s(/|$)(.*)`. Rejected because:
1. It requires a `rewrite-target` annotation that conflicts with the `/api` path when placed on the same Ingress
2. The inter-repository contract explicitly specifies no rewrite for `/s`
3. A rewrite to `/api` path (as previously documented in the spec) would break `/api/links` routes

---

### D2 — Observability Platform: duas Applications ArgoCD separadas

**Decision:** `kube-prometheus-stack` and Tempo installed as separate ArgoCD Applications in namespace `observability`, using Helm with pinned chart versions. The OTel Collector and Grafana dashboard ConfigMap remain in `k8s/observability/` via Kustomize in namespace `portal-dos-links`.

**Rationale:**
- Independent lifecycle (stack upgrades do not affect app deploys)
- CRDs (ServiceMonitor, PrometheusRule) managed by the stack before the app depends on them (sync-wave ordering)
- Grafana sidecar discovers dashboards across namespaces
- Easier to disable observability entirely for cost or debugging without touching app manifests

**ArgoCD config details:**
- `sync-wave: "0"` on the stack Applications; `sync-wave: "1"` on the portal Application
- `ServerSideApply=true` on the stack (large CRD objects exceed annotation size limit)
- `SkipDryRunOnMissingResource=true` + `retry` with exponential backoff on the portal Application (ServiceMonitor/PrometheusRule fail dry-run before CRDs exist on first sync)

---

### D3 — Métricas: ServiceMonitor

**Decision:** Prometheus scrapes Collector pods via two `ServiceMonitor` targets:
- Port 8889: application metrics (HTTP + `links.*` custom counters)
- Port 8888: Collector self-telemetry (`otelcol_*` metrics)

`resource_to_telemetry_conversion: enabled: true` in the Prometheus exporter so that `service.instance.id` (set via downward API in D6) becomes a Prometheus label — preventing counter collisions between replicas.

**kube-prometheus-stack values required:**
```yaml
prometheus:
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
grafana:
  sidecar:
    dashboards:
      searchNamespace: ALL
```

---

### D4 — Collector como Gateway Escalável

**Decision:** 2 replicas minimum, HPA on CPU/memory, PDB `minAvailable: 1`, `memory_limiter` as the first processor (before `batch`) to shed load before OOMKill, `batch` processor for efficiency, bounded queues (`queue_size: 1000`), `health_check` extension on 13133 for probes, restrictive `securityContext` (non-root, readOnlyRootFilesystem).

**Critical constraint:** the API must not depend on the Collector being available to serve requests. Telemetry export is best-effort — if the Collector is down, the API continues to function (OTel SDK uses async export with retry).

---

### D5 — Traces do Navegador: Ingress dedicado

**Decision:** `ingress-otlp.yaml` routes `/otlp` (Prefix) to `otel-collector:4318`. The Collector HTTP receiver is configured with `traces_url_path: /otlp/v1/traces` — this means the full path `/otlp/v1/traces` arriving at the Collector matches the configured path without any Ingress rewrite.

**Security — residual risk documented:** The endpoint is public and unauthenticated. A malicious actor can inject synthetic spans. Mitigations applied: `limit-rps: 100` and `proxy-body-size: 1m` annotations on the Ingress. This is an accepted risk for the hackathon scope; production hardening would add mTLS or an auth sidecar.

---

### D6 — Autoscaling e Rollout Sem Downtime

**Decision:**
- HPA `autoscaling/v2`: API (min 2, max 6, CPU 70%, `scaleDown.stabilizationWindowSeconds: 300`); Frontend (min 2, max 4, CPU 70%)
- `spec.replicas` removed from all managed Deployments (HPA owns the count; keeping `replicas` causes drift with `selfHeal: true`)
- PDB `minAvailable: 1` for API, Frontend, and Collector
- `topologySpreadConstraints` by node with `whenUnsatisfiable: ScheduleAnyway` (best-effort spread; does not block scheduling if only one node exists)
- `rollingUpdate: {maxUnavailable: 0, maxSurge: 1}` — zero-downtime rollouts
- API `preStop: exec: sleep 5` + `terminationGracePeriodSeconds: 30` — gives the Ingress controller time to remove the pod from the upstream pool before the process receives SIGTERM

**Dependency:** HPA requires `metrics-server` to be installed in the cluster (documented in README as a prerequisite).

---

### D7 — Migrações: Job com PreSync Hook

**Decision:** Replace the `initContainer` in the API Deployment with a Kubernetes `Job` annotated with `argocd.argoproj.io/hook: PreSync`. Config:
```yaml
backoffLimit: 3
ttlSecondsAfterFinished: 600
# hook-delete-policy: HookSucceeded
```

**Rationale:** The initContainer runs on every new pod — including scale-out events. This causes parallel `migrate deploy` executions, potential migration conflicts, and unnecessary latency on scale. A PreSync Job runs exactly once per ArgoCD sync, before any Deployment pods are updated.

**Rejected alternative:** corrected initContainer with `--config prisma7.config.ts`. Rejected because it still runs on every pod, including scale-out.

**Command (to be validated at runtime):**
```
npx prisma migrate deploy --config prisma7.config.ts
```
**Verification required:** confirm the Prisma 7 config file name (`prisma7.config.ts` vs `prisma.config.ts`) by inspecting `kubectl logs` of the migration Job. Do not assume the filename.

---

### D8 — Alertas: PrometheusRule

**Decision:** `PrometheusRule` versioned in `k8s/observability/`. Alert definitions:

| Alert | Expression (indicative — metric names TBD from :8889/metrics) | For |
|---|---|---|
| `APIHighErrorRate` | `rate(http_server_request_duration_seconds_count{http_response_status_code=~"5.."}[2m]) / rate(http_server_request_duration_seconds_count[2m]) > 0.02` | 5m |
| `APIHighLatency` | `histogram_quantile(0.99, rate(http_server_request_duration_seconds_bucket[2m])) > 0.5` | 10m |
| `PodsNotReady` | `kube_deployment_status_replicas_unavailable{namespace="portal-dos-links"} > 0` | 5m |
| `CollectorExportFailures` | `increase(otelcol_exporter_send_failed_spans_total[5m]) > 0` | — |
| `HPAAtMax` | `kube_horizontalpodautoscaler_status_current_replicas == kube_horizontalpodautoscaler_spec_max_replicas` | 15m |

**Note:** All metric names marked "TBD" must be verified against `curl <collector-pod>:8889/metrics` output before T9 is accepted. Rate windows are set to 2 min (≥ 4× the 30 s scrape interval). HTTP metric names depend on `OTEL_SEMCONV_STABILITY_OPT_IN=http`.

---

### D9 — Conexões do Banco: Regra do Pool

**Decision:** `PG_POOL_MAX=10` in ConfigMap `api-config`.

**Pool constraint:** `maxReplicas (6) × PG_POOL_MAX (10) = 60 connections`. PostgreSQL default `max_connections` is 100. Constraint: `60 ≤ 80% × 100 = 80`. ✅ Valid for current scale.
**Scale path (ADR — not implemented now):**
- **PgBouncer:** connection pooler between API pods and PostgreSQL; allows more app replicas without exhausting DB connections
- **CloudNativePG / managed PostgreSQL:** for production HA and connection management; the single-replica Deployment + PVC is a known limitation (documented in G9)

---

### D10 — Dashboard de Demo: cliques, latência, erros e traces na mesma tela

**Decision:** O dashboard `portal-dos-links` (uid `portal-dos-links`) evolui de 8 para 10 painéis para a demo ao vivo do hackathon, mantendo o uid e os 8 painéis existentes inalterados. Os 2 novos painéis são:

1. **Total de cliques** — `type: stat`, datasource Prometheus via `${datasource}`, `expr: sum(increase(links_redirected_total[$__range]))`. Usa `$__range` (janela selecionada no dashboard) em vez de `[2m]` fixo, porque é um total acumulado e não uma taxa. Posicionado em destaque no início da primeira linha, antes dos painéis de taxa por segundo.

2. **Traces recentes da API** — `type: table`, datasource **Tempo** (uid fixo `"tempo"`, **não** a variável `${datasource}` que é Prometheus), `queryType: traceql`, query `{ resource.service.name = "portal-dos-links-api" }`, `limit: 20`. O Trace ID é clicável por padrão nesta integração Table + TraceQL do Grafana e abre o trace no Explore — não requer data links ou overrides adicionais.

**Layout do grid (sem sobreposição):**

| Linha | Painéis (gridPos) |
|---|---|
| 1 — destaque de volume | Total de cliques + Redirects por segundo + Links criados por segundo |
| 2 — latência e erros | Latência p50/p95/p99 + Erros de negócio + Taxa de 5xx |
| 3 — traces | Traces recentes da API (largura total, 24 colunas) |
| 4 — saúde do cluster | Pods prontos + HPA + Falhas de envio do Collector |

Cada painel ocupa 8 colunas (de 24) na sua linha, exceto a linha 3 (Traces) que ocupa 24. Altura padrão de 8 unidades para os painéis timeseries/stat; o painel de traces usa altura 8.

**Refresh e janela:** `refresh: "5s"` e `time: { from: "now-15m", to: "now" }` para a demo ao vivo. O refresh de 5s é agressivo e adequado apenas para demo curta; o valor anterior era `30s`.

**Rationale:**
- O painel "Total de cliques" em destaque dá um número imediato de volume para a audiência, mais impactante que a taxa/s em uma demo
- O painel de traces na mesma tela conecta métricas e traces sem trocar de aba — o juiz vê um pico de latência e clica no trace correspondente
- O Tempo já está provisionado (uid `tempo`, url `http://tempo.observability.svc.cluster.local:3200`) em `argocd/observability/kube-prometheus-stack-values.yaml`; não há provisão adicional necessária
- A escolha de `type: table` + TraceQL (em vez do visualization `traces` puro) é porque o `traces` renderiza um único trace por traceID, exigindo uma variável `traceId` manual; a tabela lista 20 traces recentes e permite clicar

**Rejected alternative — painel `traces` com variável `traceId`:** exigiria o usuário digitar um trace ID para visualizar; inadequado para demo ao vivo onde queremos ver uma lista de traces recentes.

**Rejected alternative — TraceQL metrics query:** retornaria séries temporais agregadas, não a lista de traces clicável que o objetivo pede.

**Restrições técnicas (não alteradas):**
- O JSON do dashboard vive dentro de um ConfigMap como bloco literal `|` — aspas duplas escapadas como `\"`, indentação YAML correta
- O label do ConfigMap (`grafana_dashboard: "1"`) e o namespace (`portal-dos-links`) não mudam
- O kustomize deve continuar renderizando sem erro

**Verificação assumida (não alterada, só confirmada no cluster):**
- Label `http_route="/:code"` nas métricas `http_server_request_duration_seconds_*` (filtro de latência)
- Label `http_response_status_code` (filtro de 5xx)
- Label `service_name` (filtro de service na taxa de 5xx)
- Comando de verificação no Collector: `kubectl exec -n portal-dos-links deploy/otel-collector -- wget -qO- http://localhost:8889/metrics | grep -E 'http_server_request_duration_seconds|links_'`

---

## ArgoCD Application
## ArgoCD Application

### Portal dos Links (current + updates for T3)

```yaml
spec:
  source:
    repoURL: https://github.com/cloudops-squad-2/hackaton-portal-dos-links-gitops.git
    targetRevision: develop
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
      - ServerSideApply=true
      - SkipDryRunOnMissingResource=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

`prune: true` removes resources deleted from Git. `selfHeal: true` reverts manual `kubectl` changes — this is why `spec.replicas` must be removed from Deployments managed by HPA.

---

## Secret Handling

Secrets (`**/secret.yaml`, `**/secret.example.yaml` is the template) are **gitignored** — never committed. Apply manually before first sync:

```bash
kubectl apply -f k8s/database/secret.yaml
kubectl apply -f k8s/api/secret.yaml
```

The API secret key is `DATABASE_URL` (full Postgres connection string with URL-encoded password). The example file at `k8s/api/secret.example.yaml` is safe to commit as a template (no real values).

Upgrade path for production: replace with **Sealed Secrets** or **External Secrets Operator** for encrypted-at-rest secrets safe to commit.

---

## CI Integration (from application repo)

The application repo's `update-manifests` job:

1. Builds and pushes images tagged with the git SHA to `ghcr.io/cloudops-squad-2/`
2. Checks out this config repo on `develop` using `CONFIG_REPO_PAT`
3. Uses `yq` to patch `newTag` in `k8s/kustomization.yaml` for both images
4. Commits and pushes directly to `develop`
5. ArgoCD detects the diff and rolls out the new version automatically

> **Note:** `CONFIG_REPO_PAT` must be a GitHub PAT with `contents: write` on this repo, stored as a secret in the application repo. `yq` must be installed on the runner before the bump step.

---

## Bootstrap Order

For a fresh cluster the components must come up in this order to avoid dependency failures:

1. **ingress-nginx** — Ingress controller (Helm or manifest)
2. **metrics-server** — required for HPA to function
3. **ArgoCD** — sync controller
4. **namespace `portal-dos-links`** — create manually (secrets depend on it existing)
5. **Secrets** — apply `k8s/database/secret.yaml` and `k8s/api/secret.yaml` manually
6. **observability stack** — sync `kube-prometheus-stack` and `tempo` Applications (sync-wave 0)
7. **portal Application** — sync after CRDs are ready (sync-wave 1); ArgoCD retry handles any residual CRD timing issues

Prometheus, Grafana, and Tempo are **never exposed via public Ingress** — access via `kubectl port-forward` only.
