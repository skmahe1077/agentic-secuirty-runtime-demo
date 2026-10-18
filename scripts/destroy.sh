#!/usr/bin/env bash
# Tears down every billable resource this repo creates: the storefront
# ALB, Vault's + SPIRE's PVCs, EKS (which takes SPIRE and Vault down with
# it), RDS, the VPC, and the KMS unseal key. Run this after every
# rehearsal -- see the cost note in docs/RUNBOOK.md.
#
# Things that MUST happen before/around `terraform destroy`, or they leak
# and keep billing silently -- all confirmed the hard way on a real run,
# 2026-10-18, not theorized:
#   1. The storefront Ingress must be deleted first so the AWS Load
#      Balancer Controller deletes the ALB + target groups itself.
#      Deleting the controller (which `terraform destroy` does) does NOT
#      clean up an ALB whose Ingress still exists.
#   2. Vault's AND SPIRE's PVCs must be deleted explicitly. Helm does not
#      delete StatefulSet volumeClaimTemplate PVCs on uninstall, and
#      deleting the EKS cluster does not delete the EBS volumes behind
#      them. This script only handled Vault's PVCs for a long time --
#      SPIRE's own PVC leaked on the first real teardown because of
#      exactly this gap.
#   3. Deleting a PVC doesn't mean the EBS volume behind it is gone
#      immediately -- the CSI driver needs time to actually process the
#      deletion, and if the EKS cluster (and the CSI driver running on
#      it) is destroyed before that finishes, the volume survives as an
#      orphan. The final cleanup sweep below actively deletes anything
#      left in `available` state, rather than just reporting it -- the
#      first real run leaked 3 volumes this way (two Vault's, one
#      SPIRE's) because the old version of this step only printed a
#      table.
#   4. `vault_auth_backend.spiffe` / `vault_generic_endpoint.spiffe_config`
#      cannot actually be destroyed through Vault's API -- DELETE on
#      `auth/spiffe/config` returns HTTP 405 "unsupported operation".
#      Removed from state before the real destroy runs, rather than
#      discovered as a failure after 15 minutes of otherwise-successful
#      AWS teardown.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

warn "about to destroy the entire agentic-security-runtime-demo stack (EKS, RDS, VPC, Vault, ALB, KMS key)."
read -r -p "type 'destroy' to continue: " confirm
[ "$confirm" = "destroy" ] || die "aborted"

VAULT_NS="$(tf_output vault_k8s_namespace 2>/dev/null || echo vault)"
SPIRE_NS="spire-mgmt"

log "deleting the storefront Ingress and waiting for the ALB to disappear"
kubectl -n nimbus delete ingress storefront --ignore-not-found --timeout=180s 2>/dev/null || true
for i in $(seq 1 60); do
  remaining="$(aws elbv2 describe-load-balancers --query "LoadBalancers[?contains(LoadBalancerName, 'storefront')].LoadBalancerName" --output text 2>/dev/null || true)"
  [ -z "$remaining" ] && break
  sleep 5
done

log "deleting Vault's and SPIRE's PVCs"
kubectl -n "$VAULT_NS" delete pvc --all --ignore-not-found --timeout=180s 2>/dev/null || true
kubectl -n "$SPIRE_NS" delete pvc --all --ignore-not-found --timeout=180s 2>/dev/null || true

# The `vault` provider needs VAULT_ADDR/VAULT_TOKEN to destroy its own
# resources (policies, auth mounts, the OAuth resource-server profiles,
# the agent/human identity entities) -- without this, `terraform destroy`
# fails at the state-refresh step with "failed to configure Vault
# address" before it destroys ANYTHING. Every other script that touches
# Vault already calls this.
vault_env

log "removing the two Vault resources that can't actually be destroyed through Vault's API (DELETE on auth/spiffe/config -> 405)"
terraform -chdir="$TF_DIR" state rm vault_generic_endpoint.spiffe_config vault_auth_backend.spiffe 2>/dev/null || true

terraform -chdir="$TF_DIR" destroy -auto-approve
DESTROY_STATUS=$?
[ "$DESTROY_STATUS" -eq 0 ] || warn "terraform destroy exited $DESTROY_STATUS -- check terraform state list in $TF_DIR for anything left behind before assuming this is fully torn down."

log "confirming nothing billable was left behind"
aws eks list-clusters --query 'clusters' --output table 2>/dev/null || true
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output table 2>/dev/null || true
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output table 2>/dev/null || true
aws elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupName' --output table 2>/dev/null || true

log "deleting any EBS volumes orphaned by a PVC whose CSI deletion didn't finish before the cluster did"
orphans="$(aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].{id:VolumeId,pvc:Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value}' --output json 2>/dev/null || echo '[]')"
echo "$orphans" | python3 -c '
import json, sys
for v in json.load(sys.stdin):
    if v.get("pvc"):
        print(v["id"])
' | while read -r vol_id; do
  warn "deleting orphaned volume $vol_id (was backing a PVC that no longer exists)"
  aws ec2 delete-volume --volume-id "$vol_id" 2>&1 || true
done
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].{id:VolumeId,size:Size,pvc:Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value}' --output table 2>/dev/null || true

warn "the KMS unseal key enters a 7-day pending-deletion window and bills ~\$1/mo until it elapses -- that's expected, not a leak."
rm -f "$TF_DIR/.vault-init.json"

log "done."
