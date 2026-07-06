# saritasa-devops-build-samples-k8s

Platform / cluster-bootstrap repo for the CI/CD pipeline in
[saritasa-devops-build-samples](https://github.com/dknhat2000/saritasa-devops-build-samples).

This repo holds everything that is **not** tied to a specific commit of the app
repo: the Tekton `Pipeline`/`Task` definitions, the Kubernetes manifests needed
to bootstrap the cluster (namespaces, RBAC, resource quotas, the
Pipelines-as-Code `Repository` CR), and the `setup.sh` script that applies all
of it. Everything here is pre-applied to the cluster by `setup.sh`, by name —
see "Why everything is pre-applied" below for why that's a requirement, not a
style choice.

Only one file lives in the app repo's `.tekton/` instead: `dispatch.yaml`, a
`PipelineRun` referencing this repo's `dispatch` Pipeline by name. Pipelines-as-
Code (PAC) creates that one PipelineRun on every push/PR, regardless of which
or how many components changed.

## Dynamic component detection

The app repo used to need one static `.tekton/<component>.yaml` PipelineRun
per component, each hardcoded to match a specific path glob
(`on-path-change: [go/no-imports/**]`). That doesn't scale — adding a
component, or moving one to a new folder, meant editing Tekton config. It also
gave every component the same flat resource request regardless of whether it
was a zero-dependency Go binary or a Maven build.

Instead:

1. PAC computes the changed-files list for every push/PR itself (`files.all`)
   — the same job Tekton Triggers' GitHub interceptor's `addChangedFiles`
   feature used to do, before this project's earlier iteration migrated to
   PAC (see the app repo's history — the pre-PAC design had a
   `detect-and-dispatch` Task computing this from `changed-files`/`components.yaml`
   too; this is the same idea, moved onto PAC's CEL support). The app repo's
   `.tekton/dispatch.yaml` hands it straight to the `dispatch` Pipeline as a
   plain param: `{{ cel: files.all.join(",") }}`. No clone, no git diff,
   needed just to find out what changed.
2. `tasks/collect-and-dispatch.yaml` maps each changed path to a component
   (its top two path segments, e.g. `go/no-imports`) restricted to an
   ecosystem allowlist (`go`, `python`, `nodejs`, `java`, `php`, `ruby`,
   `dotnet-core`, `web-servers` — everything else, `tests/`, `scripts/`,
   docs, is silently ignored), resolves a resource tier per component (see
   "Resource tiers" below), and `kubectl create`s one independent
   `component-delivery` PipelineRun per component.

A new component under an already-listed ecosystem (`go/new-thing`) is
auto-detected with zero Tekton config changes. A component moving to a new
folder needs no config changes either — detection follows the changed path,
not a hardcoded list. A brand new ecosystem needs exactly one line added to
the `tier_for()`/`tier_values()` lookup in `collect-and-dispatch.yaml` — which
is unavoidable regardless, since a new ecosystem also needs its own Paketo
builder image chosen.

## Why everything is pre-applied

`collect-and-dispatch` creates PipelineRuns with a plain `kubectl create`,
bypassing PAC entirely. PAC's per-run resolution of Pipeline/Task definitions
straight from the source repo's `.tekton/` (no cluster RBAC needed) only
happens for PipelineRuns **PAC itself** creates from watching that directory —
that's just the one `dispatch` PipelineRun per push. Every PipelineRun
`collect-and-dispatch` creates after that references `component-delivery` and
`buildpacks` **by name**, so those must already exist in the cluster —
`setup.sh` applies them once, the same way it already applied the community
catalog's `git-clone`/`kubernetes-actions` Tasks.

## Layout

```
pipelines/dispatch.yaml               Pipeline: collect-and-dispatch (single task, no clone)
pipelines/component-delivery.yaml     Pipeline: fetch source -> build (buildpacks) -> rollout
tasks/collect-and-dispatch.yaml       Task: changed-files -> components -> kubectl-create PipelineRuns, tiered
tasks/buildpacks.yaml                 Task: Cloud Native Buildpacks build (Tekton catalog v0.6, customized)
manifests/tekton/                     Kustomize base: tekton namespace, RBAC, ResourceQuota/LimitRange, PAC Repository CR
manifests/dev/                        Kustomize base: dev namespace, RBAC for the pipeline service account
setup.sh                              Cluster bootstrap script (see SETUP.md)
```

See [SETUP.md](SETUP.md) for full setup instructions.

## Resource scarcity control

The build-pushing task ("push a commit touching all components at once and
don't let the pipeline fall over") needs more than a single flat cpu/memory
cap — the components in the app repo don't cost the same to build. A Go
binary with zero imports and a Java Spring Boot app pulled through
Maven/Gradle (one component even does native-image compilation) are not the
same shape of workload. So `collect-and-dispatch` resolves a **resource tier**
per component and sets `component-delivery`'s `build-*`/`layers-size-limit`
params and the dispatched PipelineRun's workspace PVC size accordingly, not
one-size-fits-all:

| Tier | CPU req/limit | Memory req/limit | Ephemeral storage req/limit | Workspace PVC | Bandwidth | Components |
|---|---|---|---|---|---|---|
| `light` | 250m / 1 | 256Mi / 512Mi | 256Mi / 512Mi | 512Mi | 10M | `go/*` — no or near-zero dependencies |
| `standard` (default) | 500m / 1 | 512Mi / 768Mi | 512Mi / 1Gi | 1Gi | 15M | `python/*`, `php/*`, `ruby/*`, `web-servers/*` — small, well-pinned dependency sets |
| `medium` | 500m / 2 | 512Mi / 1Gi | 512Mi / 2Gi | 2Gi | 20M | `nodejs/*` — `node_modules` transitive trees are heavier over the wire and on disk than an equivalent single-dependency Go/Python app |
| `heavy` | 1 / 3 | 1Gi / 3Gi | 1Gi / 6Gi | 6Gi | 40M | `java/*` (Maven/Gradle, incl. a native-image build), `dotnet-core/*` (NuGet restore) |

Ecosystems not yet in the allowlist (`docker/`, `git/`, `procfile/` in the app
repo — ambiguous whether they're meant as CNB-buildable samples or as
buildpack-detection test fixtures) aren't tiered because they aren't detected
as components at all yet; adding one is the same one-line lookup change as
adding a new ecosystem.

**Storage**, specifically, is bounded two ways per component: the workspace
PVC (git-clone output + whatever the buildpack downloads into the app's
dependency cache lives here) and the buildpacks Task's `/layers` `emptyDir`
(`layers-size-limit`, build output + CNB layer cache) — both come from the
same tier so a dependency-install blowup (e.g. an accidental `npm install`
pulling gigabytes) hits a wall sized to what that ecosystem should need, not
what the heaviest component in the repo needs.

**Network bandwidth** gets two controls, one structural and one best-effort:
- Structural, works everywhere: the buildpacks builder image
  (`paketobuildpacks/builder-jammy-base`) is pulled with
  `imagePullPolicy: IfNotPresent` (`tasks/buildpacks.yaml`) instead of
  `Always`. It's the same image for every component; on the single-node
  cluster this targets, re-pulling a 1GB+ image per component on every push
  is the single biggest avoidable network cost, and the node's local image
  cache already gives us reuse for free after the first build.
- Best-effort, CNI-dependent: `collect-and-dispatch` sets
  `kubernetes.io/ingress-bandwidth` / `.../egress-bandwidth` annotations
  directly on each dispatched PipelineRun's `metadata` (Tekton propagates
  PipelineRun annotations down to every TaskRun and Pod it creates — Tekton's
  `PodTemplate` type has no generic annotations field, so this can't be done
  via `podTemplate`), tiered the same way as CPU/memory/storage above.
  **This is only enforced if the cluster's CNI plugin implements traffic
  shaping on that annotation** (e.g. the `bandwidth` CNI meta-plugin, or
  Cilium's bandwidth manager) — minikube's default CNI does not, out of the
  box. Treat it as documentation of intent plus a lever that starts working
  the moment the CNI supports it, not as a guarantee on this specific local
  setup.

**Concurrency** works in two layers that don't overlap the way they might look
like they do:
- PAC's `concurrency_limit` (`manifests/tekton/repository.yaml`) only gates
  the one `dispatch` PipelineRun per push/PR — it has no visibility into the
  `component-delivery` PipelineRuns `collect-and-dispatch` creates directly
  with `kubectl create`, since those never go through PAC.
- The namespace `ResourceQuota`/`LimitRange` (`manifests/tekton/quota-tekton.yaml`)
  is what actually throttles concurrent component builds: pods whose tiered
  request would exceed the quota sit `Pending` and self-schedule as other
  builds finish — no failures, no manual concurrency count to tune. The quota
  is currently sized for the `light`/`standard`/`medium`/`heavy` tiers'
  realistic combinations; if a burst of `heavy`-tier builds becomes common,
  re-check the quota's totals against that worst case.
