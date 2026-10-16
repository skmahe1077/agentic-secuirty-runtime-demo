#!/usr/bin/env bash
# Shared helpers, sourced by the other scripts/*.sh files.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Pulls a terraform output into the current shell. Fails loudly if
# `terraform apply` hasn't produced it yet -- better than silently
# continuing with an empty value.
tf_output() {
  local name="$1"
  local val
  val="$(terraform -chdir="$TF_DIR" output -raw "$name" 2>/dev/null || true)"
  [ -n "$val" ] || die "terraform output '$name' is empty -- has 'terraform apply' run in $TF_DIR?"
  printf '%s' "$val"
}

VAULT_PF_PID=""
vault_portforward_stop() { [ -n "${VAULT_PF_PID:-}" ] && kill "$VAULT_PF_PID" 2>/dev/null || true; }

# Self-managed Vault has no `vault_addr`/`vault_admin_token` Terraform
# output the way HCP's admin token was -- the root token comes from an
# imperative `vault operator init` (scripts/vault-init.sh), so it has to
# be read back from where that script put it. VAULT_ADDR comes from a
# port-forward: Vault deliberately has no public ALB (see
# terraform/outputs.tf's vault_internal_addr comment).
vault_env() {
  local ns
  ns="$(tf_output vault_k8s_namespace)"

  vault_portforward_stop
  kubectl -n "$ns" port-forward svc/vault 8200:8200 >/dev/null 2>&1 &
  VAULT_PF_PID=$!
  trap vault_portforward_stop EXIT

  local i=0
  until curl -sf http://127.0.0.1:8200/v1/sys/seal-status >/dev/null 2>&1; do
    i=$((i+1))
    [ "$i" -lt 30 ] || die "port-forward to svc/vault in namespace $ns never came up"
    sleep 1
  done

  export VAULT_ADDR=http://127.0.0.1:8200
  export VAULT_TOKEN="$(vault_root_token)"
}

vault_root_token() {
  if [ -f "$TF_DIR/.vault-init.json" ]; then
    python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["root_token"])' "$TF_DIR/.vault-init.json"
  else
    aws secretsmanager get-secret-value --secret-id "$(tf_output vault_init_secret_name)" \
      --query SecretString --output text \
      | python3 -c 'import json,sys;print(json.load(sys.stdin)["root_token"])'
  fi
}

# The storefront's public ALB hostname, once provisioned; falls back to
# localhost so the trimmed docker-compose stack (postgres + storefront +
# agent-insecure) keeps working unmodified for offline UI development.
storefront_url() {
  local host
  host="$(kubectl --request-timeout=3s -n nimbus get ingress storefront -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [ -n "$host" ]; then
    printf 'http://%s' "$host"
  else
    printf 'http://localhost:8000'
  fi
}
: "${STOREFRONT_URL:=$(storefront_url)}"
