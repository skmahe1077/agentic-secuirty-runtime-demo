#!/usr/bin/env bash
# Pulls SPIRE's current JWKS bundle out of the cluster and writes both
# forms Vault needs:
#   terraform/spiffe-bundle.jwks        -- auth/spiffe's `bundle` arg
#   terraform/spiffe-bundle-keys/*.pem  -- agentic-iam.tf's OAuth resource
#                                          server profile's `public_keys`
#                                          (terraform/locals.tf reads this
#                                          directory automatically)
#
# Run this once during initial provisioning and again if the stack outlives
# ~24h -- SPIRE's signing keys are bounded by `ca_ttl` (default 24h) and a
# static bundle goes stale silently past that. See docs/RUNBOOK.md.
#
# `spire-server bundle show -format spiffe` is the documented command for
# this; sanity-check the first run's output before trusting it on stage.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

OUT_JWKS="$TF_DIR/spiffe-bundle.jwks"
OUT_KEYS_DIR="$TF_DIR/spiffe-bundle-keys"

SPIRE_SERVER_POD="$(kubectl -n spire-mgmt get pod -l app.kubernetes.io/name=server -o jsonpath='{.items[0].metadata.name}')"
[ -n "$SPIRE_SERVER_POD" ] || die "no spire-server pod found in namespace spire-mgmt"

log "fetching bundle from $SPIRE_SERVER_POD"
kubectl -n spire-mgmt exec "$SPIRE_SERVER_POD" -- \
  /opt/spire/bin/spire-server bundle show -format spiffe > "$OUT_JWKS"

[ -s "$OUT_JWKS" ] || die "bundle came back empty -- check spire-server is healthy"
log "wrote $OUT_JWKS"

log "converting JWKS keys to individual PEM files for agentic-iam.tf's OAuth resource server profile"
rm -rf "$OUT_KEYS_DIR"; mkdir -p "$OUT_KEYS_DIR"
python3 - "$OUT_JWKS" "$OUT_KEYS_DIR" <<'PYEOF'
import json, sys
import jwt  # PyJWT -- can load a JWK dict straight into a cryptography key object
from cryptography.hazmat.primitives import serialization

jwks_path, out_dir = sys.argv[1], sys.argv[2]
jwks = json.load(open(jwks_path))
for i, jwk in enumerate(jwks.get("keys", [])):
    key = jwt.PyJWK.from_json(json.dumps(jwk)).key
    pem = key.public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    path = f"{out_dir}/key-{i}.pem"
    with open(path, "wb") as f:
        f.write(pem)
    print(f"wrote {path} (kid={jwk.get('kid', '?')})")
PYEOF

log "done. terraform/locals.tf reads every file under $OUT_KEYS_DIR automatically on the next apply."
