# Portal dos Links — GitOps Config Repo

> "A stack todo mundo tem. O portal é só seu."

This repository is the **source of truth** for the Kubernetes cluster that runs the Portal dos Links — a creative cloud-native link shortener built for the CloudOps Bootcamp Hackathon.

ArgoCD watches this repo and automatically reconciles the cluster state with whatever is on the `main` branch. You do not `kubectl apply` app manifests manually — you push to Git and let ArgoCD do the work.

---

## The Application

| Component | Image | Port | Description |
|---|---|---|---|
| **API** | `ghcr.io/cloudops-squad-2/portal-dos-links-api` | 3000 | NestJS — shortens links, handles redirects |
| **Frontend** | `ghcr.io/cloudops-squad-2/portal-dos-links-frontend` | 80 | nginx serving static build |
| **Database** | `postgres:16-alpine` | 5432 | PostgreSQL — maps short codes → URLs |

---

## Repo Structure

```
.
├── argocd/
│   └── application.yaml        # ArgoCD Application CRD — registers this repo with ArgoCD
├── k8s/
│   ├── kustomization.yaml      # Root — namespace, resources, image tag overrides
│   ├── api/
│   │   ├── configmap.yaml      # Non-sensitive config (OTEL endpoint)
│   │   ├── secret.yaml         # DATABASE_URL — gitignored, apply manually
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── kustomization.yaml
│   ├── frontend/
│   │   ├── configmap.yaml      # NEXT_PUBLIC_API_URL
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── ingress.yaml        # Path-based routing: /api, /s → API; / → Frontend
│   │   └── kustomization.yaml
│   ├── database/
│   │   ├── secret.yaml         # Postgres credentials — gitignored, apply manually
│   │   ├── pvc.yaml            # 1Gi persistent volume
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── kustomization.yaml
│   └── observability/          # Coming soon — OTEL Collector + Grafana dashboards
├── .github/
│   └── workflows/
│       └── ci.yaml             # Gitleaks + kustomize build + kubeconform validation
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

> **Note:** This can take 2–3 minutes on a local cluster.

---

### Step 2 — Create the namespace

ArgoCD will create the namespace automatically on first sync via `CreateNamespace=true`, but if you need to apply secrets before that:

```bash
kubectl create namespace portal-dos-links
```

---

### Step 3 — Apply secrets manually

Secrets are **gitignored** and never committed. You must apply them manually before the first sync:

```bash
# Database credentials
kubectl apply -f k8s/database/secret.yaml

# API connection string
kubectl apply -f k8s/api/secret.yaml
```

> **Note:** If these files don't exist locally (e.g. on a fresh clone), create them first.  
> See the [Secret Reference](#secret-reference) section below.

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

Check pods:

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

---

### Step 6 — Access the ArgoCD UI (optional)

```bash
# Get the auto-generated admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Port-forward the UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open `https://localhost:8080` — accept the self-signed certificate warning and log in with `admin` and the password above.

---

## How to Deploy a New Version

The application repo CI pushes new images to GHCR tagged with the git SHA. To deploy a new version, update the image tag in the root kustomization:

```bash
# In k8s/kustomization.yaml, update newTag for the component you want to deploy:
images:
  - name: ghcr.io/cloudops-squad-2/portal-dos-links-api
    newTag: "abc1234"   # ← new SHA here
  - name: ghcr.io/cloudops-squad-2/portal-dos-links-frontend
    newTag: "abc1234"
```

Commit and push to `main`. ArgoCD detects the change within ~3 minutes and rolls out the new version automatically.

---

## Secret Reference

These files are gitignored. Create them locally before applying.

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
  POSTGRES_DB: portal
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

> **Important:** Use `postgres-svc` as the hostname — not `localhost`. That is the Kubernetes Service name the API pod uses to reach the database inside the cluster.

---

## CI Pipeline

Every push to `main` or `develop` and every PR triggers `.github/workflows/ci.yaml`:

1. **Gitleaks** — scans for accidentally committed secrets
2. **kustomize build** — renders the full manifest
3. **kubeconform** — validates rendered YAML against Kubernetes schemas (strict mode)

If the pipeline fails, ArgoCD will still attempt to sync the last successful state — it does not block on CI.

---

## Troubleshooting

### ArgoCD shows `ComparisonError: kustomization.yaml is empty`

The manifests haven't been pushed to `main` yet. ArgoCD reads from Git, not your local filesystem.

```bash
git status          # check for uncommitted changes
git log --oneline   # check your branch
git push origin main
```

---

### Pods stuck in `ImagePullBackOff`

The cluster can't pull from `ghcr.io`. Create an image pull secret:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<github-pat-with-read:packages> \
  --namespace portal-dos-links
```

Then add `imagePullSecrets` to the affected deployment.

---

### Pods in `CrashLoopBackOff`

Check the logs:

```bash
kubectl logs -n portal-dos-links deployment/portal-api --previous
kubectl logs -n portal-dos-links deployment/portal-frontend --previous
```

Common causes:
- **API** — `DATABASE_URL` secret not applied or wrong hostname (`localhost` instead of `postgres-svc`)
- **Frontend** — probe hitting wrong port (must be `80`, not `3000`)
- **Database** — secret not applied before pod started

---

### Pods stuck in `Pending`

Usually a resource or PVC issue:

```bash
kubectl describe pod -n portal-dos-links <pod-name>
```

Look for `Insufficient cpu/memory` or `no persistent volumes available`.

---

### ArgoCD sync stuck in `Progressing`

Force a refresh:

```bash
kubectl patch application portal-dos-links -n argocd \
  --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'
```

Or click **Sync** → **Force** in the ArgoCD UI.

---

### `kustomize build` fails locally

Make sure the `observability` directory is commented out in `k8s/kustomization.yaml` until Task 5 is complete:

```yaml
resources:
  - api
  - frontend
  - database
  # - observability   ← keep this commented until observability manifests exist
```

---

## How Kiro Was Used

This repository was built with [Kiro](https://kiro.aws) as AI copilot throughout the hackathon. Key contributions:

| Area | How Kiro helped |
|---|---|
| Spec & design | Generated requirements, design doc and task breakdown from the hackathon PDF |
| K8s manifests | Scaffolded all Deployments, Services, ConfigMaps, PVCs and Ingress |
| Debugging | Diagnosed probe misconfiguration (wrong ports/paths) from pod logs |
| Best practices | Suggested moving `DATABASE_URL` from ConfigMap to Secret |
| CI pipeline | Reviewed and improved the GitHub Actions workflow |
| GitOps | Wrote the ArgoCD Application manifest with automated sync policy |
| Documentation | Generated this README |
