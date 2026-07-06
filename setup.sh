#!/usr/bin/env bash
# =============================================================================
# Saritasa CI/CD — full environment setup
#
# Safe to re-run: all kubectl commands use --dry-run=client -o yaml | apply
#
# Prerequisites:
#   minikube  kubectl  ngrok  pack
#   secrets.env  (copy from secrets.env.example and fill values)
#
# Usage (run from repo root):
#   ./setup.sh             full provision from scratch
#   ./setup.sh tasks       re-apply Tasks + Pipelines only (catalog + ours)
#   ./setup.sh pac         re-apply PAC repository CR + GitHub App secret only
#   ./setup.sh dev         re-apply dev namespace + RBAC only
#   ./setup.sh webhook     restart port-forwards + ngrok tunnel
# =============================================================================
set -euo pipefail

TEKTON_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFESTS="${TEKTON_DIR}/manifests"

SECRETS_FILE="${TEKTON_DIR}/secrets.env"
PROFILE="${MINIKUBE_PROFILE:-saritasa}"
WEBHOOK_PORT="${WEBHOOK_PORT:-8080}"

K="sudo -E kubectl"

# ── Helpers ───────────────────────────────────────────────────────────────────

log()   { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[setup]\033[0m WARNING: %s\n' "$*"; }
die()   { printf '\033[1;31m[setup]\033[0m ERROR: %s\n' "$*" >&2; exit 1; }
phase() { printf '\n\033[1;37m━━━ %s ━━━\033[0m\n' "$*"; }

load_secrets() {
  [[ -f "$SECRETS_FILE" ]] || die "Missing ${SECRETS_FILE}. Copy from secrets.env.example"
  set -a && source "$SECRETS_FILE" && set +a
  for var in GITHUB_WEBHOOK_SECRET GHCR_TOKEN GITHUB_USER; do
    [[ -n "${!var:-}" ]] || die "Missing required variable ${var} in ${SECRETS_FILE}"
  done
}

require_minikube() {
  minikube -p "$PROFILE" status >/dev/null 2>&1 \
    || die "Minikube profile '${PROFILE}' is not running. Run: ./setup.sh (full)"
  minikube -p "$PROFILE" update-context >/dev/null 2>&1 || true
  $K config use-context "$PROFILE" >/dev/null 2>&1 || true
}

# ── Phase 1: Minikube ─────────────────────────────────────────────────────────

start_minikube() {
  phase "Minikube"
  if minikube -p "$PROFILE" status >/dev/null 2>&1; then
    ok "Minikube profile '${PROFILE}' already running"
  else
    log "Starting minikube profile '${PROFILE}' (4 CPU / 8 GB)"
    minikube -p "$PROFILE" start --cpus=4 --memory=8192 --driver=docker
  fi
  minikube -p "$PROFILE" update-context >/dev/null 2>&1 || true
  $K config use-context "$PROFILE" >/dev/null 2>&1 || true
}

# ── Phase 2: Tekton + PAC install ────────────────────────────────────────────

install_tekton_and_pac() {
  phase "Tekton + Pipelines as Code"

  log "Applying Tekton Pipelines"
  $K apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml

  log "Applying Tekton Triggers + Interceptors"
  $K apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
  $K apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml

  log "Applying Tekton Dashboard"
  $K apply -f https://storage.googleapis.com/tekton-releases/dashboard/latest/release.yaml

  log "Applying Pipelines as Code controller"
  $K apply -f https://raw.githubusercontent.com/openshift-pipelines/pipelines-as-code/stable/release.k8s.yaml

  log "Waiting for controllers to be available"
  $K wait --for=condition=available --timeout=180s \
    deployment/tekton-pipelines-controller \
    deployment/tekton-triggers-controller \
    -n tekton-pipelines

  $K wait --for=condition=available --timeout=120s \
    deployment/pipelines-as-code-controller \
    -n pipelines-as-code

  ok "Tekton + PAC ready"
}

# ── Phase 3: Namespace, RBAC, Secrets ────────────────────────────────────────

apply_namespace_rbac_secrets() {
  phase "Namespace + RBAC + Quota + Secrets"

  load_secrets

  log "Applying tekton namespace, ResourceQuota/LimitRange, RBAC and PAC Repository CR (Kustomize base: manifests/tekton)"
  $K apply -k "${MANIFESTS}/tekton"

  log "Applying GitHub webhook secret"
  $K create secret generic github-webhook-secret \
    --namespace=tekton \
    --from-literal=secretToken="${GITHUB_WEBHOOK_SECRET}" \
    --dry-run=client -o yaml | $K apply -f -

  log "Applying GHCR credentials (tekton namespace)"
  $K create secret docker-registry ghcr-credentials \
    --namespace=tekton \
    --docker-server=ghcr.io \
    --docker-username="${GITHUB_USER}" \
    --docker-password="${GHCR_TOKEN}" \
    --dry-run=client -o yaml | $K apply -f -

  install_git_credentials

  ok "Namespace, RBAC and secrets ready"
}

install_git_credentials() {
  local key_file="${GIT_SSH_KEY:-${HOME}/.ssh/dknhat2000_ed25519}"
  [[ -f "$key_file" ]] \
    || die "SSH private key not found: ${key_file}. Set GIT_SSH_KEY in secrets.env"

  local known_hosts config
  known_hosts="$(mktemp)"
  config="$(mktemp)"

  ssh-keyscan -t rsa,ecdsa,ed25519 github.com >"$known_hosts" 2>/dev/null \
    || die "ssh-keyscan failed — check network access to github.com"

  cat >"$config" <<'EOF'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_rsa
  IdentitiesOnly yes
EOF

  log "Creating git-credentials secret (${key_file})"
  $K create secret generic git-credentials \
    --namespace=tekton \
    --from-file=id_rsa="${key_file}" \
    --from-file=known_hosts="${known_hosts}" \
    --from-file=config="${config}" \
    --dry-run=client -o yaml | $K apply -f -

  rm -f "$known_hosts" "$config"
}

# ── Phase 4: Tasks + Pipelines ────────────────────────────────────────────────
#
# Everything here is pre-applied to the cluster, by name, once. This is required
# (not just a style choice): tasks/collect-and-dispatch.yaml creates PipelineRuns
# with a plain `kubectl create`, bypassing Pipelines-as-Code entirely — PAC's
# per-run resolution of Pipeline/Task definitions from the source repo's .tekton/
# only happens for PipelineRuns PAC itself creates from watching that directory
# (i.e. only the one `dispatch` PipelineRun the app repo's .tekton/dispatch.yaml
# triggers). Every PipelineRun `collect-and-dispatch` creates after that
# references `component-delivery`/`buildpacks` by name, so they must already
# exist in the cluster.

CATALOG="https://raw.githubusercontent.com/tektoncd/catalog/main/task"

apply_tasks_and_pipeline() {
  phase "Tasks + Pipelines"

  log "Installing git-clone v0.9 from Tekton catalog"
  $K apply -n tekton -f "${CATALOG}/git-clone/0.9/git-clone.yaml"

  log "Installing kubernetes-actions v0.2 from Tekton catalog"
  $K apply -n tekton -f "${CATALOG}/kubernetes-actions/0.2/kubernetes-actions.yaml"

  log "Applying buildpacks Task (tasks/buildpacks.yaml)"
  $K apply -n tekton -f "${TEKTON_DIR}/tasks/buildpacks.yaml"

  log "Applying collect-and-dispatch Task (tasks/collect-and-dispatch.yaml)"
  $K apply -n tekton -f "${TEKTON_DIR}/tasks/collect-and-dispatch.yaml"

  log "Applying component-delivery Pipeline (pipelines/component-delivery.yaml)"
  $K apply -n tekton -f "${TEKTON_DIR}/pipelines/component-delivery.yaml"

  log "Applying dispatch Pipeline (pipelines/dispatch.yaml)"
  $K apply -n tekton -f "${TEKTON_DIR}/pipelines/dispatch.yaml"

  ok "Tasks + Pipelines ready"
}

# ── Phase 5: Dev namespace + Deployments ─────────────────────────────────────

apply_dev_deployments() {
  phase "Dev Namespace + RBAC"

  load_secrets

  log "Applying dev namespace + pipeline-sa RBAC (Kustomize base: manifests/dev)"
  $K apply -k "${MANIFESTS}/dev"

  log "Applying GHCR credentials (dev namespace — used by imagePullSecrets)"
  $K create secret docker-registry ghcr-credentials \
    --namespace=dev \
    --docker-server=ghcr.io \
    --docker-username="${GITHUB_USER}" \
    --docker-password="${GHCR_TOKEN}" \
    --dry-run=client -o yaml | $K apply -f -

  ok "Dev namespace ready (component Deployments/Services are created by the pipeline's rollout step, not pre-applied here)"
}

# ── Phase 6: PAC Repository CR + GitHub App secret ───────────────────────────

apply_pac() {
  phase "Pipelines as Code — Repository CR"

  log "Re-applying manifests/tekton Kustomize base (includes the Repository CR; safe to re-run)"
  $K apply -k "${MANIFESTS}/tekton"

  if [[ -n "${GITHUB_APP_ID:-}" && -n "${GITHUB_APP_PRIVATE_KEY_FILE:-}" ]]; then
    [[ -f "${GITHUB_APP_PRIVATE_KEY_FILE}" ]] \
      || die "GitHub App private key not found: ${GITHUB_APP_PRIVATE_KEY_FILE}"

    log "Applying PAC GitHub App secret"
    $K create secret generic pipelines-as-code-secret \
      --namespace=pipelines-as-code \
      --from-literal=github-application-id="${GITHUB_APP_ID}" \
      --from-file=github-private-key="${GITHUB_APP_PRIVATE_KEY_FILE}" \
      --from-literal=webhook.secret="${GITHUB_WEBHOOK_SECRET}" \
      --dry-run=client -o yaml | $K apply -f -

    ok "PAC GitHub App secret configured"
  else
    warn "GITHUB_APP_ID or GITHUB_APP_PRIVATE_KEY_FILE not set — see secrets.env.example"
    warn "Re-run './setup.sh pac' after adding GitHub App credentials to secrets.env"
  fi
}

# ── Phase 7: Port-forwards + ngrok ───────────────────────────────────────────

start_webhook_tunnel() {
  phase "Port-forwards + ngrok webhook tunnel"

  require_minikube

  if ! pgrep -f "port-forward.*tekton-dashboard.*9097" >/dev/null 2>&1; then
    log "Port-forwarding Tekton Dashboard → localhost:9097"
    $K port-forward svc/tekton-dashboard 9097:9097 -n tekton-pipelines \
      >/dev/null 2>&1 &
  else
    ok "Tekton Dashboard port-forward already running"
  fi

  # PAC controller receives GitHub webhooks (replaces old EventListener)
  if ! pgrep -f "port-forward.*pipelines-as-code-controller.*${WEBHOOK_PORT}" >/dev/null 2>&1; then
    log "Port-forwarding PAC controller → localhost:${WEBHOOK_PORT}"
    $K port-forward svc/pipelines-as-code-controller \
      "${WEBHOOK_PORT}:8080" -n pipelines-as-code \
      >/dev/null 2>&1 &
    sleep 2
  else
    ok "PAC controller port-forward already running on ${WEBHOOK_PORT}"
  fi

  if ! which ngrok >/dev/null 2>&1; then
    warn "ngrok not installed — set the GitHub App webhook URL to a public URL manually"
    return
  fi

  if ! pgrep -f "ngrok http ${WEBHOOK_PORT}" >/dev/null 2>&1; then
    log "Starting ngrok on port ${WEBHOOK_PORT}"
    ngrok http "${WEBHOOK_PORT}" --log=stdout >/tmp/ngrok-pac.log 2>&1 &
    sleep 3
  fi

  local tunnel_url
  tunnel_url="$(curl -s http://localhost:4040/api/tunnels \
    | python3 -c "import sys,json; ts=json.load(sys.stdin)['tunnels']; \
      print(next(t['public_url'] for t in ts if t['public_url'].startswith('https')))" \
    2>/dev/null || true)"

  if [[ -n "$tunnel_url" ]]; then
    ok "ngrok tunnel: ${tunnel_url}/"
    ok "Dashboard:    http://localhost:9097"
  else
    warn "Could not read ngrok tunnel URL — check http://localhost:4040"
  fi
}

# ── Entrypoint ────────────────────────────────────────────────────────────────

MODE="${1:-all}"

case "$MODE" in
  all)
    start_minikube
    install_tekton_and_pac
    apply_namespace_rbac_secrets
    apply_tasks_and_pipeline
    apply_dev_deployments
    apply_pac
    start_webhook_tunnel
    ;;
  tasks)
    require_minikube
    apply_tasks_and_pipeline
    ;;
  pac)
    require_minikube
    load_secrets
    apply_pac
    ;;
  dev)
    require_minikube
    apply_dev_deployments
    ;;
  webhook)
    start_webhook_tunnel
    ;;
  *)
    echo "Usage: $0 [all|tasks|pac|dev|webhook]"
    exit 1
    ;;
esac

ok "Done"
