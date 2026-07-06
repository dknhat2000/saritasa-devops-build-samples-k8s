# Tekton + Pipelines as Code — Setup Guide

All commands run from the **repo root** unless stated otherwise.
The setup script lives at `setup.sh`. Subcommands can re-run individual phases.

```
./setup.sh [all|tasks|pac|dev|webhook]
```

---

## Prerequisites

| Tool | Purpose |
|------|---------|
| `minikube` | Local Kubernetes cluster |
| `kubectl` | Cluster management |
| `ngrok` | Expose PAC controller to GitHub webhooks |
| `pack` (Buildpacks CLI) | Local build testing |
| `gh` (GitHub CLI) | Webhook / App inspection |

---

## Phase 0 — Secrets file

Copy and fill in the template before running anything:

```bash
cp secrets.env.example secrets.env
```

Required keys:

| Key | Description |
|-----|-------------|
| `GITHUB_WEBHOOK_SECRET` | HMAC secret set in the GitHub App settings |
| `GHCR_TOKEN` | GitHub PAT with `write:packages` scope |
| `GITHUB_USER` | GitHub username (e.g. `dknhat2000`) |
| `GITHUB_APP_ID` | Numeric App ID from the App settings page |
| `GITHUB_APP_PRIVATE_KEY_FILE` | Path to the downloaded `.pem` private key |

---

## Phase 1 — Minikube

```bash
./setup.sh          # full run starts here, or:
minikube -p saritasa start --cpus=4 --memory=8192 --driver=docker
```

The script uses profile `saritasa` by default. Override with `MINIKUBE_PROFILE=<name>`.

---

## Phase 2 — Install Tekton + Pipelines as Code

```bash
./setup.sh          # included in full run, or run it alone by editing setup.sh
```

Installs (from upstream release manifests):
- Tekton Pipelines controller
- Tekton Triggers + Interceptors
- Tekton Dashboard (`localhost:9097` after Phase 7)
- Pipelines as Code controller (`pipelines-as-code` namespace)

Waits for all controllers to reach `Available` before continuing.

---

## Phase 3 — Namespace, RBAC, Secrets

```bash
./setup.sh          # included in full run
```

Applies the `manifests/tekton` Kustomize base (tekton namespace, RBAC,
ResourceQuota/LimitRange, PAC Repository CR — see README.md) and creates:

| Resource | Purpose |
|----------|---------|
| `manifests/tekton` (Kustomize) | `tekton` namespace, ResourceQuota/LimitRange, `pipeline-sa` RBAC (incl. `pipelineruns: create/get/list`, needed by `collect-and-dispatch`), PAC task-reader RBAC, PAC Repository CR |
| `github-webhook-secret` | HMAC secret for PAC webhook validation |
| `ghcr-credentials` | Docker registry secret for image push |
| `git-credentials` | SSH key for the `git-clone` task |

The SSH key defaults to `~/.ssh/dknhat2000_ed25519`. Override with `GIT_SSH_KEY` in `secrets.env`.

---

## Phase 4 — Tasks + Pipelines

```bash
./setup.sh tasks    # re-apply after any task/pipeline change
```

Applied to the `tekton` namespace:

| File | Description |
|------|-------------|
| `git-clone` (Tekton catalog v0.9) | Clones source repo into shared workspace |
| `kubernetes-actions` (Tekton catalog v0.2) | Runs the `kubectl apply` rollout step |
| `tasks/buildpacks.yaml` | Builds OCI image via Paketo buildpacks, pushes to GHCR |
| `tasks/collect-and-dispatch.yaml` | Maps changed-files to components, tiers them, `kubectl create`s one `component-delivery` PipelineRun per component |
| `pipelines/component-delivery.yaml` | fetch-source → build-image → rollout, for one component |
| `pipelines/dispatch.yaml` | collect-and-dispatch, for the whole push/PR |

All of these are pre-applied here and referenced **by name** — see README.md
"Why everything is pre-applied" for why that's required, not just tidy. The
app repo's `.tekton/dispatch.yaml` is the only PAC-resolved-from-source-repo
object left; PAC reads it directly from the source commit, not from here.

---

## Phase 5 — Dev Namespace

```bash
./setup.sh dev      # re-apply after RBAC changes
```

Applies the `manifests/dev` Kustomize base and creates:

| Resource | Purpose |
|----------|---------|
| `manifests/dev` (Kustomize) | `dev` namespace, `pipeline-role-dev` RBAC (`deployments: create/get/list/watch/patch/update` — `create` matters: see README.md on the idempotent `kubectl apply` rollout) |
| `ghcr-credentials` (dev ns) | `imagePullSecrets` for app containers |

There's nothing else to pre-apply here: no placeholder Deployments and no
Services. Each component's Deployment is created (or updated) by
`component-delivery`'s rollout step on its first successful build — see the
app repo's README/ARCHITECTURE for why there's intentionally no Service.

---

## Phase 6 — GitHub App Setup (one-time, manual)

Before running this phase, create a GitHub App:

1. Go to `https://github.com/settings/apps/new`
2. Fill in:
   - **App name**: e.g. `dknhat2000-tekton-pac`
   - **Homepage URL**: your GitHub profile or repo URL
   - **Webhook URL**: the ngrok URL from Phase 7 (update this whenever ngrok restarts)
   - **Webhook secret**: value of `GITHUB_WEBHOOK_SECRET` in `secrets.env`
3. Under **Permissions**, grant:
   - Repository → Checks: Read & Write
   - Repository → Contents: Read-only
   - Repository → Pull requests: Read & Write
   - Repository → Commit statuses: Read & Write
4. Under **Subscribe to events**, check: `Push`, `Pull request`
5. Create the App → note the **App ID**
6. Generate a **Private key** → download the `.pem` file
7. Copy the private key to `~/.ssh/`:

```bash
cp ~/Downloads/<app>.private-key.pem ~/.ssh/pac-github-app.pem
chmod 600 ~/.ssh/pac-github-app.pem
```

8. **Install the App** on the repository:
   - Go to `https://github.com/settings/apps/<app-name>/installations`
   - Click Install → select `dknhat2000/saritasa-devops-build-samples`

9. Update `secrets.env` with `GITHUB_APP_ID` and `GITHUB_APP_PRIVATE_KEY_FILE`.

---

## Phase 6b — Apply PAC Repository CR

```bash
./setup.sh pac      # apply after any GitHub App credential change
```

Re-applies the `manifests/tekton` Kustomize base, which includes:
- `manifests/tekton/repository.yaml` — Repository CR matching the GitHub repo URL, `concurrency_limit: 4` (gates concurrent `dispatch` PipelineRuns only — see README.md "Resource scarcity control")

Applies to `pipelines-as-code` namespace:
- `pipelines-as-code-secret` — GitHub App ID, private key, webhook HMAC secret

---

## Phase 7 — Webhook Tunnel

```bash
./setup.sh webhook  # restart port-forwards + ngrok after minikube restart
```

Starts (if not already running):
- Port-forward: `pipelines-as-code-controller` → `localhost:8080`
- Port-forward: `tekton-dashboard` → `localhost:9097`
- `ngrok http 8080` — exposes the PAC controller publicly

After ngrok starts, copy the `https://` tunnel URL and update the GitHub App webhook URL:  
`https://github.com/settings/apps/<app-name>` → Webhook URL

> ngrok free tier assigns a new URL on each restart. Update the GitHub App webhook URL each time.

---

## Verify end-to-end

```bash
# Watch PipelineRuns appear after a push
kubectl get pipelineruns -n tekton -w

# PAC controller logs — look for "Creating PipelineRun"
kubectl logs -n pipelines-as-code -l app=pipelines-as-code-controller -f

# Tekton Dashboard
open http://localhost:9097
```

A successful push to `feat/*` or `main` should:
1. PAC receives the webhook → matches `.tekton/dispatch.yaml` (every push/PR matches — there's no path filter)
2. PAC creates one `dispatch` PipelineRun in the `tekton` namespace, with `changed-files` already populated from `files.all`
3. `collect-and-dispatch` runs: maps changed files to components, prints its decision to stdout (including a no-op message if nothing buildpack-ready changed), and `kubectl create`s one `component-delivery` PipelineRun per component
4. Each `component-delivery` PipelineRun runs: clone → build (pushes image to GHCR) → rollout (`kubectl apply`s the Deployment in `dev`, then `kubectl rollout status`)
5. PAC posts the `dispatch` PipelineRun's pass/fail as a GitHub Check Run — it does not see the dynamically-created `component-delivery` runs, since those bypass PAC (see README.md "Why everything is pre-applied")

```bash
# Watch the dispatch decision as it happens
kubectl logs -n tekton -l tekton.dev/pipelineTask=collect-and-dispatch -f --tail=50

# Watch the fanned-out component builds appear
kubectl get pipelineruns -n tekton -l saritasa.dev/pipeline-role=build-deploy -w
```

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| No `dispatch` PipelineRun created | PAC logs: `kubectl logs -n pipelines-as-code -l app=pipelines-as-code-controller` |
| `dispatch` runs but no component PipelineRuns | `collect-and-dispatch` logs (see above) — likely the changed paths aren't under an allowlisted ecosystem (README.md "Resource tiers"), or `changed-files` came back empty |
| `pipelineruns.tekton.dev is forbidden` in `collect-and-dispatch` logs | `pipeline-sa` is missing the `pipelineruns: create` RBAC grant — re-run `./setup.sh` (Phase 3) |
| `cannot find referenced pipeline` | The referenced Pipeline (`dispatch` or `component-delivery`) isn't applied to the cluster — re-run `./setup.sh tasks` |
| `client setup failed` | GitHub App not installed on the repo — see Phase 6 step 8 |
| `image pull backoff` in `dev` | `ghcr-credentials` secret missing in `dev` ns — re-run `./setup.sh dev` |
| Deployment never created for a component | Check `pipeline-role-dev` grants `create` on `deployments` (not just `patch`/`update`) — re-run `./setup.sh dev` |
| No GitHub Check Run on PR | GitHub App not installed or missing Checks: Read & Write permission — see Phase 6 |
| ngrok URL changed | Update GitHub App webhook URL, re-run `./setup.sh webhook` |
