# City Population API

A containerized FastAPI service that stores city population data in
Elasticsearch, packaged for Kubernetes via a modular Helm v3 chart, with
Docker Compose support for local end-to-end testing.

```
sre-city-population/
├── app/
│   ├── main.py                    # FastAPI application
│   ├── requirements.txt           # Pinned runtime dependencies
│   ├── requirements-dev.txt       # + pytest, ruff, bandit
│   └── tests/test_main.py         # Unit tests (mocked Elasticsearch client)
├── Dockerfile                      # Multi-stage, non-root, minimal image
├── .dockerignore
├── docker-compose.yml              # Local API + Elasticsearch stack
├── helm/
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── _helpers.tpl
│       ├── elasticsearch.yaml          # StatefulSet + headless Service + PVC
│       ├── deployment.yaml             # App Deployment + PDB + optional HPA
│       ├── service.yaml                # App Service
│       ├── secret.yaml                 # ES credentials (dev convenience)
│       ├── secretproviderclass.yaml    # Optional: Key Vault via CSI driver
│       ├── networkpolicy.yaml          # Isolates Elasticsearch
│       └── NOTES.txt
├── terraform/                      # Part E: AKS + ACR + supporting infra
│   ├── versions.tf                 # Providers + remote state backend
│   ├── variables.tf
│   ├── main.tf                     # RG, networking, Log Analytics, ACR, AKS
│   ├── key_vault.tf                 # Azure Key Vault + AKS CSI wiring
│   ├── identity.tf                  # GitHub OIDC App Registration + role assignments
│   ├── outputs.tf
│   └── dev.tfvars.example
├── .github/workflows/
│   ├── ci-cd.yaml                  # Part F: lint/test/scan/build/push/GitOps update
│   └── terraform.yaml              # Plan on PR, apply on merge to main
├── argocd/                         # Part G: GitOps deployment
│   ├── project.yaml                # AppProject (scopes what ArgoCD may touch)
│   └── application.yaml            # Application (syncs helm/ to AKS)
├── scripts/
│   └── bootstrap-tfstate.sh        # One-time remote state storage setup
└── README.md                       # This file
```

---

## Deployment Guide

### Prerequisites
- Docker + Docker Compose
- A local Kubernetes cluster: [Kind](https://kind.sigs.k8s.io/) or
  [Minikube](https://minikube.sigs.k8s.io/)
- `kubectl` and `helm` v3 CLIs
- `curl` for testing

### 1. Run locally with Make (fastest path)

**Automated smoke test via Makefile:**

```bash
# Start API + Elasticsearch in the background
make compose-up

# Run end-to-end checks for /health, upsert, query, 404, and 422 behavior
make smoke-test

# Tear down
make compose-down
```

This starts a single-node Elasticsearch and the API, with the API waiting
(via its own startup retry logic) for Elasticsearch to become healthy
before serving traffic. The API is exposed at `http://localhost:8000`.

**Test it:**

```bash
# Health check
curl http://localhost:8000/health
# {"status":"OK"}

# Upsert a city
curl -X POST http://localhost:8000/cities \
  -H "Content-Type: application/json" \
  -d '{"city": "Warsaw", "population": 1863056}'
# {"city":"Warsaw","population":1863056,"updated_at":"..."}

# Update the same city (upsert)
curl -X POST http://localhost:8000/cities \
  -H "Content-Type: application/json" \
  -d '{"city": "Warsaw", "population": 1870000}'

# Query it
curl http://localhost:8000/cities/Warsaw
# {"city":"Warsaw","population":1870000,"updated_at":"..."}

# Query a city that doesn't exist -> structured 404
curl -i http://localhost:8000/cities/Atlantis
# HTTP/1.1 404 Not Found
# {"error":"city_not_found","detail":"No population data found for city 'Atlantis'.","request_id":"..."}
```


Interactive API docs (Swagger UI) are available at `http://localhost:8000/docs`.

Tear down: `docker compose down -v`

### 2. Build the container image directly

```bash
docker build -t city-population-api:1.0.0 .
```

### 3. Spin up a local Kubernetes cluster

**Using Kind:**

```bash
kind create cluster --name city-population
kind load docker-image city-population-api:1.0.0 --name city-population
```

**Using Minikube:**

```bash
minikube start
minikube image load city-population-api:1.0.0
# Alternatively, build directly inside Minikube's Docker daemon:
# eval $(minikube docker-env)
# docker build -t city-population-api:1.0.0 .
```

### 4. Deploy with Helm

```bash
helm install city-population ./helm \
  --set app.image.repository=city-population-api \
  --set app.image.tag=1.0.0

kubectl rollout status deployment/city-population-api
```

Check that everything came up:

```bash
kubectl get pods
kubectl get pvc
kubectl get statefulset
```

### 5. Access the API

```bash
kubectl port-forward svc/city-population-api 8000:80
```

Then run the same `curl` commands from step 1 against `http://localhost:8000`.

### 6. Upgrade / uninstall

```bash
helm upgrade city-population ./helm
helm uninstall city-population
```

Note: the Elasticsearch PVC is not deleted automatically by `helm
uninstall` (by design, to prevent accidental data loss). Remove it
explicitly if you want a clean slate:

```bash
kubectl delete pvc -l app.kubernetes.io/component=database
```

---

## Infrastructure as Code (Terraform → AKS + ACR)

`terraform/` provisions everything the app needs on Azure: a resource
group, a VNet/subnet, Log Analytics (Container Insights), Azure Container
Registry, an AKS cluster (system + autoscaling user node pool, Azure AD
Workload Identity enabled, Azure CNI + network policy, AAD RBAC), a Key
Vault, and an Azure AD App Registration federated for GitHub Actions OIDC
(no client secrets stored anywhere).

### One-time setup

```bash
# 1. Bootstrap the remote state storage account (idempotent, run once per env)
./scripts/bootstrap-tfstate.sh dev westeurope

# 2. Edit the tfvars for your environment if any changes
cd terraform
vim dev.tfvars
# set github_repository to your actual "org/repo"

# 3. Init with the backend values printed by the bootstrap script
terraform init \
  -backend-config="resource_group_name=<tfstate-rg>" \
  -backend-config="storage_account_name=<tfstate-sa>" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=city-population/dev.tfstate"

# 4. Plan and apply
terraform plan  -var-file=dev.tfvars
terraform apply -var-file=dev.tfvars
```

### Wire the outputs into GitHub

```bash
terraform output acr_login_server
terraform output acr_name
terraform output github_actions_client_id
terraform output github_actions_tenant_id
terraform output github_actions_subscription_id
```

In the GitHub repo (Settings → Secrets and variables → Actions), set:

| Name | Type | Value |
|---|---|---|
| `AZURE_CLIENT_ID` | Secret | `github_actions_client_id` output |
| `AZURE_TENANT_ID` | Secret | `github_actions_tenant_id` output |
| `AZURE_SUBSCRIPTION_ID` | Secret | `github_actions_subscription_id` output |
| `ACR_NAME` | Variable | `acr_name` output |
| `ACR_LOGIN_SERVER` | Variable | `acr_login_server` output |
| `TF_STATE_RG` / `TF_STATE_SA` / `TF_STATE_CONTAINER` / `TF_STATE_KEY` | Variables | printed by `bootstrap-tfstate.sh` |

No password/secret ever needs to be stored: `AZURE_CLIENT_ID` +
`AZURE_TENANT_ID` + `AZURE_SUBSCRIPTION_ID` are used with `azure/login@v2`'s
OIDC flow, trusted via the federated credentials created in
`terraform/identity.tf` (scoped to this exact repo + GitHub Environment).

Get cluster credentials locally:

```bash
$(terraform output -raw get_credentials_command)
```

> **Note on validation:** this chart/config was authored and syntax-reviewed
> carefully, but `terraform validate`/`helm lint` could not be executed in
> the environment that produced this repo (no outbound access to
> releases.hashicorp.com). Run both locally before your first `apply`:
> `terraform fmt -recursive && terraform validate` and `helm lint ./helm`.

---

## CI/CD Pipeline (GitHub Actions + DevSecOps)

`.github/workflows/ci-cd.yaml` runs on every push/PR touching `app/`,
`Dockerfile`, or `helm/`:

1. **Lint & test** — `ruff` (style/correctness), `pytest` (16 unit tests
   against a mocked Elasticsearch client — no live cluster needed), results
   published as a check-run annotation.
2. **SAST** — `bandit` scans `main.py` for insecure code patterns; results
   uploaded as SARIF to GitHub Code Scanning.
3. **Secret scanning** — `gitleaks` scans the full git history on every run
   so a credential can't slip in via a squashed/rebased commit.
4. **Dockerfile lint** — `hadolint` catches insecure or inefficient
   Dockerfile patterns (e.g. missing pinned versions, running as root).
5. **IaC scanning** — `checkov` and `tfsec` scan `terraform/`, `helm/`, and
   the `Dockerfile` for misconfigurations (open ingress, missing encryption,
   overly broad IAM, etc.), uploaded as SARIF.
6. **Build & image scan** — builds the image with Buildx (layer-cached via
   `type=gha`), then `trivy` scans it for CRITICAL/HIGH CVEs — **the
   pipeline fails the build** if any are found (`exit-code: 1`), so
   vulnerable images never reach ACR.
7. **Push & sign** — only after every prior gate passes, the image is
   pushed to ACR and keylessly signed with `cosign` (using the same GitHub
   OIDC identity — no signing key to manage/rotate).
8. **GitOps update** — the pipeline does **not** run `kubectl apply` or
   `helm upgrade` itself. It bumps `app.image.tag` (and
   `app.image.repository`) in `helm/values.yaml` and commits that change
   back to `main`. ArgoCD (Part G) detects the commit and reconciles the
   cluster — the classic GitOps split between CI (build/test/scan) and CD
   (sync), which also means the CI identity never needs cluster-admin.

`.github/workflows/terraform.yaml` is a separate pipeline for
infrastructure changes: `terraform plan` runs on every PR touching
`terraform/` and is posted as a PR comment for review; `terraform apply`
runs only on merge to `main`, gated behind the `dev` GitHub Environment
(configure required reviewers there for a manual approval gate before
infrastructure changes land).

**Why two pipelines?** The app pipeline's identity only needs `AcrPush` +
AKS "Cluster User" (read kubeconfig) — it can't modify infrastructure. The
Terraform pipeline needs materially broader Azure permissions
(Contributor + User Access Administrator scoped to the resource group) to
manage AKS/ACR/networking themselves. Keeping them separate means a
compromised app-build workflow can push a bad image (caught by the scans
above) but can't, say, open up the AKS API server to the internet.

---

## GitOps Deployment (ArgoCD)

### Install ArgoCD on the cluster (one-time)

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl -n argocd rollout status deployment/argocd-server

# Initial admin password (rotate this immediately, or switch to SSO):
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

### Register the app

```bash
kubectl apply -f argocd/project.yaml
kubectl apply -f argocd/application.yaml
```

Before applying, edit the `repoURL` in both files to point at your actual
fork/repo (they default to a placeholder `your-org/city-population` URL,
matching `github_repository` in your `terraform/dev.tfvars`).

### How it stays in sync

`argocd/application.yaml` sets `syncPolicy.automated` with `prune: true`
and `selfHeal: true`: ArgoCD polls (and/or receives a webhook from) the Git
repo, and whenever `helm/` changes — most commonly the automated image-tag
bump from `ci-cd.yaml`'s `update-manifests` job — it renders the chart and
applies the diff to the `city-population` namespace, removing any
resources deleted from Git and reverting any manual `kubectl edit` drift.
This is the same "declarative desired state lives in Git, ArgoCD
continuously reconciles the cluster to match it" model used in Part F.

### Access the ArgoCD UI

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
# https://localhost:8080  (user: admin)
```

Or install the CLI and log in non-interactively:

```bash
argocd login localhost:8080 --username admin --password <password> --insecure
argocd app get city-population
argocd app sync city-population   # manual sync, if automated sync is ever paused
```

### Promoting to a second environment (e.g. prod)

Duplicate `argocd/application.yaml` (e.g. `application-prod.yaml`) pointing
at a `prod` values overlay and a `prod` namespace/AKS cluster provisioned
via `terraform apply -var-file=prod.tfvars`. For more than two
environments, consider replacing the individual `Application` files with
an ArgoCD `ApplicationSet` templated over a list of environments.

---

## SRE Reflection & Production Roadmap

### Encountered Challenges

**Startup dependency ordering.** Kubernetes does not guarantee that the
Elasticsearch Pod is ready before the API Pod starts, and Compose's
`depends_on` only tracks container start, not application readiness. The
API resolves this in two ways: (1) an async retry loop with backoff in the
`lifespan` handler that polls Elasticsearch via `ping()`/`cluster.health()`
before the app accepts traffic, and (2) a `readinessProbe` pointed at
`/health/ready` (which itself checks the ES connection) so Kubernetes
never routes traffic to a Pod whose database dependency isn't up yet. The
plain `/health` liveness endpoint deliberately does *not* depend on
Elasticsearch, so a transient ES blip doesn't trigger a needless Pod
restart via `livenessProbe` — only readiness is affected, which is the
correct signal to remove the Pod from the Service's endpoints.

**Reliable volume mounts / permissions.** The official Elasticsearch image
runs as a non-root `elasticsearch` user and expects its data directory to
be writable by that UID. On some CSI storage classes (and consistently on
Kind/Minikube's default provisioner), a freshly provisioned PVC is
`root`-owned, causing Elasticsearch to fail to start with permission
errors. This is handled with an `initContainer` that `chown`s the mounted
volume before the main container starts, plus `fsGroup` in the Pod
security context as a second line of defense. `vm.max_map_count` (required
by Elasticsearch's mmap-based storage) is also not settable from inside an
unprivileged container, so a second `initContainer` applies the sysctl at
the node level before the main container starts.

**Idempotent upserts without an external ID.** The spec doesn't define a
canonical city identifier, and a naive `POST` doing an ES `index` call per
request without a stable document ID would create duplicate documents on
every "upsert" of the same city under Elasticsearch's default
auto-generated IDs. The API instead derives a deterministic document ID
from a normalized (trimmed, lower-cased) version of the city name, so
repeated upserts of "Warsaw", "warsaw", or " Warsaw " all converge on a
single document — matching the intended upsert semantics.

**Read-only root filesystem vs. runtime writes.** Hardening the Pod with
`readOnlyRootFilesystem: true` broke Python/uvicorn's need for a writable
temp directory. Fixed with a small `emptyDir` mounted at `/tmp`, keeping
the rest of the filesystem immutable.

**Terraform state and CI/CD identity are their own bootstrap problem.**
Remote state storage can't itself be created by the Terraform it backs
(handled with the small idempotent `scripts/bootstrap-tfstate.sh`), and the
GitHub Actions OIDC identity that Terraform provisions
(`terraform/identity.tf`) is also the identity `terraform apply` needs to
already be running as. In practice this means the very first `apply` for a
new environment has to run from an operator's local `az login` session (or
an existing broader identity); after that, subsequent runs can use the
federated GitHub identity. This chicken-and-egg step is called out
explicitly here rather than glossed over, since it's a common source of
"the pipeline can't bootstrap itself" surprises.

**Separating CI (build/scan) from CD (sync) cleanly.** It was tempting to
have the GitHub Actions pipeline run `helm upgrade --install` directly
against the cluster after a successful build — it's fewer moving parts.
The tradeoff is that CI then needs write access to the cluster, and there's
no single source of truth for "what's actually deployed" other than
whatever the last pipeline run happened to push. Committing the image tag
bump to Git and letting ArgoCD reconcile from there costs one extra hop
but means the cluster state is always derivable from a Git commit, drift
is self-healed automatically, and a rollback is just a `git revert`.

### Production Scaling Architecture

**High Availability**
- Move Elasticsearch from the single-node dev StatefulSet in this chart to
  a proper multi-role topology: dedicated master-eligible nodes (3, for
  quorum), separate data nodes, and optionally ingest/coordinating nodes,
  each as its own StatefulSet/values group.
- Set `number_of_replicas >= 1` on the index (this chart currently leaves
  it as the ES default) so a single node loss doesn't lose data, and pair
  with `discovery.zen`/`cluster.initial_master_nodes` style config
  appropriate to the ES version in use.
- Use **pod anti-affinity** (`requiredDuringSchedulingIgnoredDuringExecution`
  on `topology.kubernetes.io/zone`) so master/data Pods are spread across
  Azure Availability Zones, combined with AKS node pools that span zones.
- Apply a `PodDisruptionBudget` per role (already scaffolded for the app
  and optionally for ES) so voluntary disruptions (node drains, cluster
  upgrades) can't take out a quorum of master nodes at once.
- Move from `emptyDir`/single PVC to **Azure Disk (Premium SSD)** or
  **Azure Files** with a `StorageClass` using `WaitForFirstConsumer`
  binding, plus a snapshot/backup policy (ES snapshot repository backed by
  **Azure Blob Storage** via the `repository-azure` plugin).
- Put the API `Deployment` behind an `HorizontalPodAutoscaler` (already
  present, disabled by default) driven by CPU and/or custom
  request-latency metrics.

**Observability Stack**
- Expose Prometheus metrics from the API via
  [`prometheus-fastapi-instrumentator`](https://github.com/trallnag/prometheus-fastapi-instrumentator)
  (or a hand-rolled `/metrics` endpoint) and scrape with a
  `ServiceMonitor`/`PodMonitor` if using the kube-prometheus-stack, or via
  the `prometheus.io/scrape` Pod annotations already set in `values.yaml`
  for annotation-based scraping.
- Ship the structured JSON stdout logs (already implemented in
  `main.py`'s `JSONFormatter`) via **FluentBit** as a DaemonSet, forwarding
  to **Azure Monitor / Log Analytics** or a self-hosted ELK/OpenSearch
  stack for correlation with the same Elasticsearch technology used for
  application data (kept as separate clusters/indices from app data).
- Instrument distributed tracing with OpenTelemetry's FastAPI
  instrumentation, exporting to Azure Application Insights or an
  OTLP-compatible backend, correlated via the `X-Request-ID` header the
  API already generates/propagates.
- Alert on the four golden signals: request error rate, p95/p99 latency
  (from the per-request duration already logged), saturation
  (CPU/memory vs. `resources.limits`), and Elasticsearch cluster health
  (red/yellow status).

**Security Hardening**
- Replace the chart's convenience `Secret` (plaintext `values.yaml`
  credentials) with the **Secrets Store CSI Driver** backed by **Azure Key
  Vault**, or **HashiCorp Vault** with the Vault Agent Injector, so
  credentials are never stored in Helm release state or Git.
- Enforce the `NetworkPolicy` already scaffolded (Elasticsearch only
  accepts ingress from API Pods and other ES Pods on the transport port)
  and add a default-deny policy per namespace, explicitly allowlisting
  required egress (DNS, Key Vault, monitoring endpoints).
- Enable `xpack.security.enabled=true` on Elasticsearch for production
  (disabled here for local/dev simplicity), with TLS between API and ES
  and mutual TLS between ES nodes, certificates issued via
  **cert-manager**.
- Continue enforcing non-root execution, `readOnlyRootFilesystem`,
  dropped Linux capabilities, and `seccompProfile: RuntimeDefault` (already
  in `values.yaml`) — and add **Azure Policy for AKS** / OPA Gatekeeper
  admission control to make these mandatory cluster-wide rather than
  chart-level opt-in.
- Scan images in CI (Trivy/Grype) and sign them (cosign/Notary) before
  they're allowed to deploy; pin base images by digest rather than tag for
  production releases.
- Use **Azure AD Workload Identity** for any Azure resource access
  (Key Vault, Blob Storage snapshots) instead of static service principal
  credentials.

---

## Notes

- **Health check** → `GET /health` returns `{"status": "OK"}` exactly as
  specified; `GET /health/ready` is an additional, DB-aware endpoint used
  by the Kubernetes readiness probe (not required by the spec, but a
  standard SRE practice to separate liveness from readiness).
- **Upsert endpoint** → `POST /cities` with `{"city": "...", "population": N}`.
- **Query endpoint** → `GET /cities/{city_name}`, 404 with a structured
  JSON error body when not found.
- **Database** → Elasticsearch, per the "preferred" option in the spec,
  using the official async `elasticsearch` Python client.
- **Kubernetes packaging** → Helm v3 chart, application and database
  layers separated into distinct templates and `values.yaml` sections as
  requested.
