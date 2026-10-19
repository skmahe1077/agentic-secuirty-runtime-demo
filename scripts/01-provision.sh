#!/usr/bin/env bash
# Stands up the whole stack from nothing: AWS infra + self-managed Vault
# Enterprise on EKS, SPIRE on the same cluster, the app images and
# manifests, then Vault's own config -- in that order, because:
#   - the kubernetes/helm Terraform providers need EKS to exist first
#     (their config is derived from `module.eks`'s outputs, which are
#     unknown on an empty-state plan);
#   - Vault's root token comes from an imperative `vault operator init`
#     (scripts/vault-init.sh), not a Terraform resource attribute, so it
#     has to run between two separate `terraform apply`s;
#   - Vault's SPIFFE config needs SPIRE's JWKS bundle, and SPIRE needs the
#     cluster to exist first.
# This ordering is a real constraint of the architecture, not script
# laziness -- see docs/RUNBOOK.md.
#
# All three `terraform apply` calls below use -auto-approve. Confirmed the
# hard way (2026-10-19, first re-provision after a full teardown): without
# it, a non-interactive run (no human present to type "yes" at an
# unpredictable moment mid-script) just gets "error asking for approval:
# EOF" and aborts before creating anything. Running this script at all is
# already the deliberate, explicit action -- same reasoning as
# scripts/destroy.sh's -auto-approve.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

IMAGE_REGISTRY="${IMAGE_REGISTRY:?set IMAGE_REGISTRY to an ECR repo URI, e.g. 123456789012.dkr.ecr.eu-west-1.amazonaws.com/agentic-sec-demo}"
IMAGE_TAG="${IMAGE_TAG:-$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo latest)}"
LEGACY_DB_PASSWORD="${LEGACY_DB_PASSWORD:?set LEGACY_DB_PASSWORD -- see app/db/03_legacy_role.sql for the matching role, created once by hand against RDS}"
STOREFRONT_DB_PASSWORD="${STOREFRONT_DB_PASSWORD:?set STOREFRONT_DB_PASSWORD -- see app/db/04_storefront_role.sql, created once by hand against RDS}"
# Must match terraform/variables.tf's `name` / `vault_license_secret_name`
# defaults (or your terraform.tfvars overrides) -- not read from Terraform
# state here since that would need `terraform init` to have already run.
NAME="${NAME:-agentic-sec-demo}"
VAULT_LICENSE_SECRET_NAME="${VAULT_LICENSE_SECRET_NAME:-agentic-sec-demo/vault-license}"
ALB_INBOUND_CIDRS="${ALB_INBOUND_CIDRS:-0.0.0.0/0}"

log "Phase 0 -- credentials and license"
aws sts get-caller-identity >/dev/null || die "run 'aws sso login' (or equivalent) first"
aws secretsmanager describe-secret --secret-id "$VAULT_LICENSE_SECRET_NAME" >/dev/null \
  || die "Vault Enterprise license secret '$VAULT_LICENSE_SECRET_NAME' not found -- create it first: aws secretsmanager create-secret --name '$VAULT_LICENSE_SECRET_NAME' --secret-string \"\$(cat vault.hclic)\""

log "Phase A -- AWS infra (VPC, EKS, RDS, KMS, IRSA roles) -- no kubernetes/helm/vault resources yet"
terraform -chdir="$TF_DIR" init
# kubernetes_annotations.gp2_default MUST be in this phase, not left for
# the later full apply (Phase F) -- confirmed live (2026-10-19, second
# provisioning run): SPIRE's PVC (Phase D, which runs before Phase F)
# stays Pending forever ("unbound immediate PersistentVolumeClaims")
# without it. This is the exact "gp2 isn't actually the cluster-default
# StorageClass" gotcha docs/RUNBOOK.md already documents for Vault's own
# PVC -- it turns out to apply to SPIRE's PVC too, and SPIRE needs it
# earlier in the phase order than Vault does.
terraform -chdir="$TF_DIR" apply -auto-approve \
  -target=module.vpc -target=module.eks -target=module.ebs_csi_irsa \
  -target=aws_db_subnet_group.nimbus -target=aws_security_group.rds -target=aws_db_instance.nimbus \
  -target=aws_kms_key.vault_unseal -target=aws_kms_alias.vault_unseal -target=aws_iam_policy.vault_unseal \
  -target=module.vault_irsa -target=module.lbc_irsa \
  -target=aws_secretsmanager_secret.vault_init \
  -target=kubernetes_annotations.gp2_default

# NOT `tf_output aws_region` -- confirmed live (2026-10-19, second
# provisioning run): a bare `var.X`-only output never gets written during
# a targeted apply (same class of bug terraform/outputs.tf's
# vault_k8s_namespace comment already documents for a different output;
# aws_region itself was never fixed the same way). This output has a real
# dependency into Phase A's targeted module.eks, so it populates reliably.
eval "$(tf_output eks_update_kubeconfig_command)"

log "Phase B -- platform charts: Vault Enterprise + the AWS Load Balancer Controller"
terraform -chdir="$TF_DIR" apply -auto-approve \
  -target=kubernetes_namespace.vault -target=kubernetes_secret.vault_license \
  -target=helm_release.vault -target=helm_release.aws_load_balancer_controller
log "vault-0 will show 0/1 Ready until Phase C -- that's expected, not a failure"

log "Phase C -- initialize and unseal Vault"
"$REPO_ROOT/scripts/vault-init.sh"

log "Phase D -- SPIRE on the cluster"
helm repo add spiffe https://spiffe.github.io/helm-charts-hardened/ >/dev/null
helm repo update spiffe >/dev/null
helm upgrade --install --create-namespace -n spire-mgmt spire-crds spire-crds \
  --repo https://spiffe.github.io/helm-charts-hardened/
helm upgrade --install -n spire-mgmt spire spire \
  --repo https://spiffe.github.io/helm-charts-hardened/ \
  -f "$REPO_ROOT/k8s_manifests/spire/values.yaml"
kubectl -n spire-mgmt rollout status statefulset/spire-server --timeout=180s
kubectl -n spire-mgmt rollout status daemonset/spire-agent --timeout=180s

log "Phase E -- fetching SPIRE's JWKS bundle for Vault's static config"
"$REPO_ROOT/scripts/refresh-bundle.sh"

log "Phase F -- full terraform apply (vault-config.tf + agentic-iam.tf are resolvable now)"
vault_env
terraform -chdir="$TF_DIR" apply -auto-approve

log "Phase G -- build and push images, deploy the app"
aws ecr get-login-password | docker login --username AWS --password-stdin "${IMAGE_REGISTRY%%/*}"
# --platform linux/amd64 is NOT optional -- confirmed live, repeatedly
# (most recently 2026-10-19): a plain `docker build` on Apple Silicon
# produces an arm64 image, which crashes every pod on these x86_64 EKS
# nodes with "exec format error". docs/RUNBOOK.md already documented this
# as a confirmed gotcha from the first provisioning run; it was only ever
# fixed by hand in the terminal that session, never written back into
# this script -- hence it recurring here.
docker build --platform linux/amd64 -f "$REPO_ROOT/app/storefront/Dockerfile" -t "$IMAGE_REGISTRY/storefront:$IMAGE_TAG" "$REPO_ROOT"
docker build --platform linux/amd64 -f "$REPO_ROOT/app/agent/Dockerfile" -t "$IMAGE_REGISTRY/agent:$IMAGE_TAG" "$REPO_ROOT"
docker push "$IMAGE_REGISTRY/storefront:$IMAGE_TAG"
docker push "$IMAGE_REGISTRY/agent:$IMAGE_TAG"

export IMAGE_REGISTRY IMAGE_TAG NAME ALB_INBOUND_CIDRS LEGACY_DB_PASSWORD STOREFRONT_DB_PASSWORD
export RDS_ENDPOINT="$(tf_output rds_endpoint)"
export DB_NAME="nimbus"
export VAULT_ADDR="$(tf_output vault_internal_addr)"
# k8s_manifests/agent-secure/secret-obo.yaml's signing key -- same
# throwaway key terraform/obo.tf registered on the "obo-probe" OAuth
# resource-server profile. Generate it first if this is a from-scratch
# provision: `python3 scripts/mint_rar_jwt.py --keys-dir
# terraform/obo-probe-keys --sub human-approver --actor-sub agent-secure
# --out /tmp/obo_setup.jwt` (scripts/05-verify-obo.sh's own setup step
# does this too, idempotently).
export OBO_PRIVATE_KEY_PEM_B64="$(base64 < "$REPO_ROOT/terraform/obo-probe-keys/rar_probe_key.pem" | tr -d '\n')"

kubectl apply -f "$REPO_ROOT/k8s_manifests/00-namespaces.yaml"
for f in "$REPO_ROOT"/k8s_manifests/agent-insecure/*.yaml \
         "$REPO_ROOT"/k8s_manifests/agent-secure/*.yaml \
         "$REPO_ROOT"/k8s_manifests/order-agent/*.yaml \
         "$REPO_ROOT"/k8s_manifests/storefront/*.yaml; do
  envsubst < "$f" | kubectl apply -f -
done
kubectl -n nimbus rollout status deployment/storefront --timeout=120s
kubectl -n nimbus rollout status deployment/agent-insecure --timeout=120s
kubectl -n agents rollout status deployment/agent-secure --timeout=120s
kubectl -n agents rollout status deployment/order-agent --timeout=120s

log "waiting for the storefront ALB to come up (2-4 min is normal)"
for i in $(seq 1 60); do
  ALB_HOST="$(kubectl -n nimbus get ingress storefront -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [ -n "$ALB_HOST" ] && curl -sf -o /dev/null "http://$ALB_HOST/api/products" && break
  sleep 5
done
[ -n "${ALB_HOST:-}" ] || warn "ALB did not come up within 5 minutes -- check 'kubectl -n nimbus describe ingress storefront'"

log "Phase H -- Vault's imperative config step + the go/no-go gates"
"$REPO_ROOT/scripts/02-configure-vault.sh"
"$REPO_ROOT/scripts/03-verify.sh"
"$REPO_ROOT/scripts/04-verify-agentic-iam.sh"

log "done. storefront: http://${ALB_HOST:-<pending>}  (narrow ALB_INBOUND_CIDRS before the talk, not after)"
log "vault: $(tf_output vault_portforward_command)"
