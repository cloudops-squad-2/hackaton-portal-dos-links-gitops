# Portal dos Links — GitOps Config Repo

> "A stack todo mundo tem. O portal é só seu."

This repository is the **source of truth** for the Kubernetes cluster that runs the Portal dos Links — a creative cloud-native link shortener built for the CloudOps Bootcamp Hackathon.

ArgoCD watches this repo and automatically reconciles the cluster state with whatever is on the `develop` branch. You do not `kubectl apply` app manifests manually — you push to Git and let ArgoCD do the work.

---

## The Application

| Component | Image | Port | Description |
|---|---|---|---|
| **API** | `ghcr.io/cloudops-squad-2/portal-dos-links-api` | 3000 | NestJS — shortens links, handles redirects |
| **Frontend** | `ghcr.io/cloudops-squad-2/portal-dos-links-frontend` | 80 | nginx serving Vite static build |
| **Database** | `postgres:16-alpine` | 5432 | PostgreSQL — maps short codes → URLs |

---

## Repo Structure

```
.
├── argocd/
│   └── application.yaml          # ArgoCD Application CRD — registers this repo with ArgoCD
├── k8s/
│   ├── kustomization.yaml        # Root — namespace, resources, image tag overrides
│   ├── api/
│   │   ├── configmap.yaml        # Non-sensitive config (OTEL endpoint only)
│   │   ├── secret.yaml           # DATABASE_URL — gitignored, apply manually
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── kustomization.yaml
│   ├── frontend/
│   │   ├── deployment.yaml       # No ConfigMap — Vite bakes env vars at build time
│   │   ├── service.yaml
│   │   ├── ingress-api.yaml      # /api and /s paths → API (with nginx rewrite)
│   │   ├── ingress-frontend.yaml # / path → Frontend (no rewrite)
│   │   └── kustomization.yaml
│   ├── database/
│   │   ├── secret.yaml           # Postgres credentials — gitignored, apply manually
│   │   ├── pvc.yaml              # 1Gi persistent volume
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── kustomization.yaml
│   └── observability/            # Coming soon — OTEL Collector + Grafana dashboards
├── .github/
│   └── workflows/
│       └── ci.yaml               # Gitleaks + kustomize build + kubeconform validation
├── .gitignore
└── README.md
```

---

## Prerequisites

Make sure you have these tools installed:

- [`kubectl`](https://kubernetes.io/docs/tasks/tools/) — Kubernetes CLI
- [`kustomize`](https://kubectl.docs.kubernetes.io/installation/kustomize/) >= 5.4.3
- [`argocd` CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/) (optional, for managing ArgoCD from terminal)
- Access to a Kubernetes cluster (kind, minikube, or remote)
- Access to the GitHub Container Registry (`ghcr.io/cloudops-squad-2/`)

---

## Bootstrap (first time setup)

### Step 1 — Install ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Wait for all pods to be ready:

```bash
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=120s
```

> **Note:** This can take 2–3 minutes on a local cluster. If it times out, run the command again — pods may still be pulling images.

---

### Step 2 — Create the namespace

ArgoCD creates the namespace automatically on first sync (`CreateNamespace=true`), but secrets must be applied before the sync runs. Create the namespace manually first:

```bash
kubectl create namespace portal-dos-links
```

> **Note:** If you skip this step, `kubectl apply -f k8s/api/secret.yaml` will fail with `namespaces "portal-dos-links" not found`.

---

### Step 3 — Apply secrets manually

Secrets are **gitignored** and never committed. You must create and apply them before the first sync.

See the [Secret Reference](#secret-reference) section for the exact YAML. Then apply:

```bash
kubectl apply -f k8s/database/secret.yaml
kubectl apply -f k8s/api/secret.yaml
```

> **Note:** These secrets must exist before the API and database pods start. If pods are already running without them, restart the deployments after applying:
> ```bash
> kubectl rollout restart deployment/portal-api deployment/postgres -n portal-dos-links
> ```

---

### Step 4 — Register the Application with ArgoCD

```bash
kubectl apply -f argocd/application.yaml
```

---

### Step 5 — Watch the sync

```bash
kubectl get application -n argocd portal-dos-links -w
```

You should see: `OutOfSync` → `Syncing` → `Synced`

Then verify pods:

```bash
kubectl get pods -n portal-dos-links
```

Expected output:

```
NAME                               READY   STATUS    RESTARTS
portal-api-xxx                     1/1     Running   0
portal-api-xxx                     1/1     Running   0
portal-frontend-xxx                1/1     Running   0
portal-frontend-xxx                1/1     Running   0
postgres-xxx                       1/1     Running   0
```

> **Note:** If pods show `0/1` with restarts, see [Troubleshooting](#troubleshooting).

---

### Step 6 — Access the ArgoCD UI (optional)

```bash
# Get the auto-generated admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Port-forward the UI (run in a separate terminal — it stays open)
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open `https://localhost:8080` in your browser. Accept the self-signed certificate warning (click **Advanced → Proceed**) and log in with username `admin` and the password from above.

---

## How to Deploy a New Version

The application repo CI automatically bumps image tags via the `update-manifests` job. For a manual deploy, update the tag in `k8s/kustomization.yaml`:

```yaml
images:
  - name: ghcr.io/cloudops-squad-2/portal-dos-links-api
    newTag: "abc1234"   # ← replace with the new git SHA
  - name: ghcr.io/cloudops-squad-2/portal-dos-links-frontend
    newTag: "abc1234"
```

Commit and push to `develop`. ArgoCD detects the change within ~3 minutes and rolls out the new version automatically.

---

## Secret Reference

These files are **gitignored**. Create them locally on each machine that needs to bootstrap the cluster.

**`k8s/database/secret.yaml`**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
  namespace: portal-dos-links
type: Opaque
stringData:
  POSTGRES_USER: portal
  POSTGRES_PASSWORD: <your-password>
  POSTGRES_DB: portal       # must match the database name in DATABASE_URL
```

**`k8s/api/secret.yaml`**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: api-secret
  namespace: portal-dos-links
type: Opaque
stringData:
  DATABASE_URL: "postgres://portal:<your-password>@postgres-svc:5432/portal"
```

> **Important:**
> - Use `postgres-svc` as the hostname — **not** `localhost`. That is the Kubernetes Service name the API uses inside the cluster.
> - The database name in `DATABASE_URL` (`portal`) **must match** `POSTGRES_DB` in the database secret.
> - The password in `DATABASE_URL` **must match** `POSTGRES_PASSWORD` in the database secret.

---

## CI Pipeline

Every push to `main` or `develop` and every PR triggers `.github/workflows/ci.yaml`:

1. **Gitleaks** — scans for accidentally committed secrets
2. **kustomize build** — renders the full manifest to `rendered.yaml`
3. **kubeconform** — validates rendered YAML against Kubernetes schemas (strict mode)

> **Note:** ArgoCD syncs independently of CI. A failing pipeline does not block ArgoCD from syncing the last committed state.

---

## Troubleshooting

### ArgoCD shows `kustomization.yaml is empty` or `ComparisonError`

ArgoCD reads from Git — not your local files. The manifests haven't been pushed to `develop` yet.

```bash
git status                  # check for uncommitted changes
git log --oneline -5        # confirm you're on the right branch
git push origin develop
```

---

### Namespace not found when applying secrets

```
Error from server (NotFound): namespaces "portal-dos-links" not found
```

Create the namespace first:

```bash
kubectl create namespace portal-dos-links
```

---

### Pods stuck in `ImagePullBackOff` or `ErrImagePull`

The cluster cannot pull from `ghcr.io`. The registry may be private. Create an image pull secret:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<github-pat-with-read:packages> \
  --namespace portal-dos-links
```

Then add to the affected deployment under `spec.template.spec`:

```yaml
imagePullSecrets:
  - name: ghcr-pull-secret
```

---

### Pods in `CrashLoopBackOff` — app starts but keeps restarting

The app itself is starting but being killed. Get the logs from the previous (crashed) container:

```bash
kubectl logs -n portal-dos-links deployment/portal-api --previous
kubectl logs -n portal-dos-links deployment/portal-frontend --previous
```

Common causes:

| Symptom | Cause | Fix |
|---|---|---|
| API logs show clean startup but pod restarts | Liveness probe failing — wrong port or path | Probe must be `GET /api/health` on port `3000` |
| Frontend restarts ~40s after start | nginx SIGQUIT — probe hitting wrong port | Probe must be `GET /` on port `80` (not `3000`) |
| API crashes with DB connection error | `DATABASE_URL` secret not applied, or using `localhost` as host | Apply secret; use `postgres-svc` as hostname |
| Database pod crashes immediately | `postgres-secret` not applied | Apply `k8s/database/secret.yaml` first |

---

### Pods stuck in `Pending`

The pod can't be scheduled. Describe it to see why:

```bash
kubectl describe pod -n portal-dos-links <pod-name>
```

Common causes:
- `Insufficient cpu` or `Insufficient memory` — cluster doesn't have enough resources. Lower requests in the deployment or add nodes
- `no persistent volumes available` — no `StorageClass` available for the PVC. Check with `kubectl get storageclass`
- `Unschedulable: 0/1 nodes are available` — only one node and it has taints. Check with `kubectl describe nodes`

---

### ArgoCD sync stuck in `Progressing` or never reaches `Synced`

First check the sync details in the UI or CLI:

```bash
kubectl describe application -n argocd portal-dos-links
```

Force a re-sync:

```bash
kubectl patch application portal-dos-links -n argocd \
  --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'
```

Or in the ArgoCD UI: **Sync → Force**.

If the error is about a missing resource (e.g. CRD not installed), install the dependency first.

---

### ArgoCD shows `OutOfSync` right after syncing

Usually means `selfHeal` is fighting a manual `kubectl apply`. ArgoCD will revert any manual changes — this is by design. Always make changes through Git, never directly with `kubectl` on managed resources.

---

### `kustomize build k8s/` fails locally

Check if `observability` is listed in `k8s/kustomization.yaml` before the directory exists:

```yaml
resources:
  - api
  - frontend
  - database
  # - observability   ← keep commented until observability manifests are created
```

Also make sure each subdirectory has its own `kustomization.yaml`. Kustomize requires it for every directory listed as a resource.

---

### Application repo CI fails to push tag bump to this repo

The `update-manifests` job needs `CONFIG_REPO_PAT` set as a secret in the application repo. The PAT must have `contents: write` permission on this repository. Also ensure `yq` is installed in that job before the bump step.

---

### ArgoCD UI login — `argocd-initial-admin-secret` not found

The secret is deleted after the first login on some installations. Reset the password:

```bash
argocd admin initial-password -n argocd
# or reset via bcrypt:
kubectl -n argocd patch secret argocd-secret \
  -p '{"stringData":{"admin.password":"<bcrypt-hash>","admin.passwordMtime":"'$(date +%FT%T%Z)'"}}'
```

---

## How Kiro Was Used

This repository was built with [Kiro](https://kiro.aws) as AI copilot throughout the hackathon. Key contributions:

| Area | How Kiro helped |
|---|---|
| Spec & design | Generated requirements, design doc and task breakdown from the hackathon PDF |
| K8s manifests | Scaffolded all Deployments, Services, ConfigMaps, PVCs and Ingresses |
| Debugging | Diagnosed probe misconfiguration (wrong ports/paths) from pod logs in real time |
| Architecture | Identified Ingress rewrite breaking frontend static assets — split into two Ingresses |
| Best practices | Moved `DATABASE_URL` from ConfigMap to Secret; removed dead Vite ConfigMap |
| CI pipeline | Reviewed and improved the GitHub Actions validation workflow |
| GitOps | Wrote the ArgoCD Application manifest with automated sync policy |
| Documentation | Generated and maintained this README across multiple iterations |
