#!/usr/bin/env bash
# Stands up the whole stack from nothing: AWS infra + HCP Vault Dedicated,
# SPIRE on the new cluster, the app images and manifests, then Vault's own
# config -- in that order, because Vault's SPIFFE config needs SPIRE's
# JWKS bundle, and SPIRE needs the cluster to exist first. This ordering is
# a real constraint of the architecture, not an artifact of script
# laziness -- see docs/RUNBOOK.md.
#
# NOT YET RUN END TO END: written against expired AWS/HCP credentials in
# the environment this was built in (see Phase 1 below). Re-authenticate,
# then run this once and fix forward from whatever breaks first -- the
# individual terraform/*.tf and k8s_manifests/*.yaml files were validated
# with `terraform validate` / `kubeconform`, but `terraform apply` and
# `kubectl apply` themselves have not been exercised against real AWS/HCP.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

IMAGE_REGISTRY="${IMAGE_REGISTRY:?set IMAGE_REGISTRY to an ECR repo URI, e.g. 123456789012.dkr.ecr.eu-west-1.amazonaws.com/agentic-sec-demo}"
IMAGE_TAG="${IMAGE_TAG:-$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo latest)}"

log "Phase 0 -- credentials"
aws sts get-caller-identity >/dev/null || die "run 'aws sso login' (or equivalent) first"
hcp profile display >/dev/null 2>&1 || die "run 'hcp auth login' first"

log "Phase A -- AWS infra + HCP Vault cluster (everything except vault-config.tf)"
terraform -chdir="$TF_DIR" init
terraform -chdir="$TF_DIR" apply \
  -target=module.vpc -target=module.eks -target=aws_db_instance.nimbus \
  -target=aws_security_group.rds -target=aws_db_subnet_group.nimbus \
  -target=hcp_hvn.main -target=hcp_aws_network_peering.main \
  -target=aws_vpc_peering_connection_accepter.main -target=hcp_hvn_route.to_vpc \
  -target=aws_route.to_hvn -target=hcp_vault_cluster.main \
  -target=hcp_vault_cluster_admin_token.main

aws eks update-kubeconfig --region "$(tf_output aws_region)" --name "$(tf_output eks_cluster_name)"

log "Phase B -- SPIRE on the new cluster"
helm repo add spiffe https://spiffe.github.io/helm-charts-hardened/ >/dev/null
helm repo update spiffe >/dev/null
helm upgrade --install --create-namespace -n spire-mgmt spire-crds spire-crds \
  --repo https://spiffe.github.io/helm-charts-hardened/
helm upgrade --install -n spire-mgmt spire spire \
  --repo https://spiffe.github.io/helm-charts-hardened/ \
  -f "$REPO_ROOT/k8s_manifests/spire/values.yaml"
kubectl -n spire-mgmt rollout status statefulset/spire-server --timeout=180s
kubectl -n spire-mgmt rollout status daemonset/spire-agent --timeout=180s

log "fetching SPIRE's JWKS bundle for Vault's static config"
"$REPO_ROOT/scripts/refresh-bundle.sh"

log "Phase C -- full terraform apply (now the bundle file exists)"
terraform -chdir="$TF_DIR" apply

log "Phase D -- build and push images, deploy the app"
aws ecr get-login-password | docker login --username AWS --password-stdin "${IMAGE_REGISTRY%%/*}"
docker build -f "$REPO_ROOT/app/storefront/Dockerfile" -t "$IMAGE_REGISTRY/storefront:$IMAGE_TAG" "$REPO_ROOT"
docker build -f "$REPO_ROOT/app/agent/Dockerfile" -t "$IMAGE_REGISTRY/agent:$IMAGE_TAG" "$REPO_ROOT"
docker push "$IMAGE_REGISTRY/storefront:$IMAGE_TAG"
docker push "$IMAGE_REGISTRY/agent:$IMAGE_TAG"

export IMAGE_REGISTRY IMAGE_TAG
export RDS_ENDPOINT="$(tf_output rds_endpoint)"
export DB_NAME="nimbus"
export DB_MASTER_USERNAME="$(tf_output db_master_username)"
export DB_MASTER_PASSWORD="$(tf_output rds_master_password)"
export VAULT_ADDR="$(tf_output vault_addr)"
export VAULT_AUTH_METHOD="${VAULT_AUTH_METHOD:-jwt}"
export VAULT_AUTH_MOUNT="${VAULT_AUTH_MOUNT:-jwt}"
export LEGACY_DB_PASSWORD="${LEGACY_DB_PASSWORD:?set LEGACY_DB_PASSWORD -- see app/db/03_legacy_role.sql for the matching role, created once by hand against RDS}"

kubectl apply -f "$REPO_ROOT/k8s_manifests/00-namespaces.yaml"
for f in "$REPO_ROOT"/k8s_manifests/agent-insecure/*.yaml \
         "$REPO_ROOT"/k8s_manifests/agent-secure/*.yaml \
         "$REPO_ROOT"/k8s_manifests/storefront/*.yaml; do
  envsubst < "$f" | kubectl apply -f -
done
kubectl -n nimbus rollout status deployment/storefront --timeout=120s
kubectl -n nimbus rollout status deployment/agent-insecure --timeout=120s
kubectl -n agents rollout status deployment/agent-secure --timeout=120s

log "Phase E -- Vault's imperative config step + the go/no-go gate"
"$REPO_ROOT/scripts/02-configure-vault.sh"
"$REPO_ROOT/scripts/03-verify.sh"

log "done. kubectl -n nimbus port-forward svc/storefront 8000:8000, then open http://localhost:8000"
