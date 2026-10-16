#!/usr/bin/env bash
# Tears down every billable resource this repo creates: the storefront
# ALB, Vault's PVCs, EKS (which takes SPIRE and Vault down with it), RDS,
# the VPC, and the KMS unseal key. Run this after every rehearsal -- see
# the cost note in docs/RUNBOOK.md.
#
# Two things MUST happen before `terraform destroy`, or they leak and
# keep billing silently:
#   1. The storefront Ingress must be deleted first so the AWS Load
#      Balancer Controller deletes the ALB + target groups itself.
#      Deleting the controller (which `terraform destroy` does) does NOT
#      clean up an ALB whose Ingress still exists.
#   2. Vault's PVCs must be deleted explicitly. Helm does not delete
#      StatefulSet volumeClaimTemplate PVCs on uninstall, and deleting
#      the EKS cluster does not delete the EBS volumes behind them.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

warn "about to destroy the entire agentic-security-runtime-demo stack (EKS, RDS, VPC, Vault, ALB, KMS key)."
read -r -p "type 'destroy' to continue: " confirm
[ "$confirm" = "destroy" ] || die "aborted"

VAULT_NS="$(tf_output vault_k8s_namespace 2>/dev/null || echo vault)"

log "deleting the storefront Ingress and waiting for the ALB to disappear"
kubectl -n nimbus delete ingress storefront --ignore-not-found --timeout=180s 2>/dev/null || true
for i in $(seq 1 60); do
  remaining="$(aws elbv2 describe-load-balancers --query "LoadBalancers[?contains(LoadBalancerName, 'storefront')].LoadBalancerName" --output text 2>/dev/null || true)"
  [ -z "$remaining" ] && break
  sleep 5
done

log "deleting Vault's PVCs"
kubectl -n "$VAULT_NS" delete pvc --all --ignore-not-found --timeout=180s 2>/dev/null || true

terraform -chdir="$TF_DIR" destroy

log "confirming nothing billable was left behind"
aws eks list-clusters --query 'clusters' --output table 2>/dev/null || true
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output table 2>/dev/null || true
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output table 2>/dev/null || true
aws elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupName' --output table 2>/dev/null || true
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].{id:VolumeId,size:Size,pvc:Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value}' --output table 2>/dev/null || true

warn "the KMS unseal key enters a 7-day pending-deletion window and bills ~\$1/mo until it elapses -- that's expected, not a leak."
rm -f "$TF_DIR/.vault-init.json"

log "done."
