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

# STOREFRONT_URL lets every demo-beat*.sh / reset.sh work unmodified
# against either the local docker-compose stack or a `kubectl port-forward`
# to the real EKS deployment.
: "${STOREFRONT_URL:=http://localhost:8000}"
