#!/usr/bin/env bash
# `vault operator init` is an ACTION with an unrepeatable output (a root
# token and a set of KMS recovery keys), not desired state -- the same
# reason `database/rotate-root` lives in scripts/02-configure-vault.sh
# rather than in a Terraform resource. With HCP, Terraform got its admin
# token from a resource attribute; with self-managed Vault this script is
# where the token comes from, and it must run between the two terraform
# applies (see scripts/01-provision.sh's Phase B / Phase C boundary).
#
# Idempotent: safe to re-run. If the cluster is already initialized it
# only re-exports the token.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

NS="$(tf_output vault_k8s_namespace)"
INIT_SECRET="$(tf_output vault_init_secret_name)"
INIT_FILE="$TF_DIR/.vault-init.json"

log "waiting for vault-0 to be Running"
warn "it will NOT become Ready until this script finishes -- vault-helm's readiness probe execs 'vault status', which fails while uninitialized"
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Running pod/vault-0 --timeout=300s

# `vault status` exits non-zero both when sealed and when uninitialized,
# so inspect the JSON rather than the exit code.
initialized="$(kubectl -n "$NS" exec vault-0 -- vault status -format=json 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["initialized"])' 2>/dev/null || echo False)"

if [ "$initialized" = "True" ]; then
  log "already initialized -- skipping init"
else
  log "vault operator init (auto-unseal via AWS KMS -- this produces RECOVERY keys, not unseal keys)"
  kubectl -n "$NS" exec vault-0 -- vault operator init \
    -format=json -recovery-shares=5 -recovery-threshold=3 > "$INIT_FILE"

  # Two copies on purpose: Secrets Manager is the durable record that
  # survives a laptop; the gitignored local file is what every other
  # script reads without an extra AWS call per invocation.
  aws secretsmanager put-secret-value \
    --secret-id "$INIT_SECRET" --secret-string "file://$INIT_FILE" >/dev/null
  log "root token + 5 recovery keys stored in Secrets Manager '$INIT_SECRET' and $INIT_FILE (gitignored)"
  warn "the recovery keys are the ONLY way back if the KMS unseal key is ever deleted -- do not rely solely on the local file"
fi

log "waiting for the pod to auto-unseal"
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Running pod/vault-0 --timeout=120s

vault_env
log "cluster state:"
vault status
vault read -format=json sys/license/status \
  | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"];print("license expires:", d.get("autoloaded",{}).get("expiration_time", d))'
