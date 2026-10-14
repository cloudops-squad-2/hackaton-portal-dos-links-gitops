# Requirements — GitOps Config Repo (Portal dos Links)

## Context

This repository is the **source of truth** for the Kubernetes cluster that runs the Portal dos Links hackathon project. It contains no application source code — only the infrastructure configuration that ArgoCD watches and reconciles against the cluster.

The application is a creative link-shortener with three runtime components:
- **frontend** — UI to create and list shortened links
- **api** — shortening logic and redirect handler
- **database** — PostgreSQL that maps short codes → original URLs

Every component is instrumented with OpenTelemetry. Grafana dashboards surface clicks, latency, and errors in real time.

---

## Requirements

### R1 — Kubernetes Manifests (per component)

Each of the three components (`frontend`, `api`, `database`) must have a complete set of Kubernetes manifests inside `k8s/<component>/`:

- **R1.1** `Deployment` with:
  - Image tag sourced from a `kustomize` image override (so CI only needs to bump a tag, not edit YAML)
  - Resource requests and limits set
  - `livenessProbe` and `readinessProbe` configured
  - Environment variables injected from `ConfigMap` and `Secret` refs (never hardcoded values)
- **R1.2** `Service` exposing the correct port(s)
- **R1.3** `ConfigMap` for non-sensitive configuration (e.g., API base URL, OTEL collector endpoint)
- **R1.4** `Secret` (sealed or placeholder) for sensitive data (e.g., DB credentials, connection strings)
- **R1.5** For the **database** only: a `PersistentVolumeClaim` to persist data across pod restarts

### R2 — Kustomize Root

- **R2.1** `k8s/kustomization.yaml` must reference all three component directories as resources
- **R2.2** The root kustomization must expose `images:` overrides for all three components so automated tag bumps are a single-field change
- **R2.3** A `namespace` field must be declared so all resources land in a dedicated namespace (`portal-dos-links`)

### R3 — ArgoCD Application

- **R3.1** `argocd/application.yaml` must define an ArgoCD `Application` resource pointing at this repo and the `k8s/` path
- **R3.2** Sync policy must be **automated** with `prune: true` and `selfHeal: true` so the cluster self-corrects on drift
- **R3.3** The Application must target the correct destination namespace (`portal-dos-links`) and cluster (`in-cluster`)
- **R3.4** `syncOptions` must include `CreateNamespace=true` so the namespace is auto-created on first sync

### R4 — Observability Stack Configuration

- **R4.1** A `k8s/observability/` directory must contain manifests (or Kustomize component) for:
  - OpenTelemetry Collector (`Deployment` + `Service` + `ConfigMap` with pipeline: OTLP receiver → Jaeger/Tempo exporter + Prometheus exporter)
  - Grafana `ConfigMap` for a pre-built dashboard JSON (clicks counter, p99 latency, error rate panels)
- **R4.2** The root kustomization must include the `observability` directory
- **R4.3** The OTEL collector endpoint must be the value stored in the `ConfigMap` referenced by `api` and `frontend` deployments (single source of truth, no duplication)

### R5 — Ingress / Networking

- **R5.1** An `Ingress` (or `HTTPRoute` if using Gateway API) for the frontend and API services, using a hostname configurable via Kustomize patches
- **R5.2** The redirect endpoint (`GET /:code`) on the API must be reachable directly — no auth middleware in the path

### R6 — Repo Hygiene

- **R6.1** A root `README.md` must explain: project identity/mascot, folder structure, how to bootstrap ArgoCD, how to trigger a deploy, and how the Kiro copilot was used
- **R6.2** Secrets must never be committed in plaintext — use `stringData` placeholders marked `# REPLACE_ME` or integrate Sealed Secrets
- **R6.3** All YAML files must pass `kubectl --dry-run=client` or `kustomize build | kubeval` without errors
