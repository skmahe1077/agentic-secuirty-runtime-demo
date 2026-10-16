#!/usr/bin/env python3
"""LOCAL DEV ONLY. Mints a JWT carrying an RFC 9396 `authorization_details`
claim, for testing whether Vault's OAuth-resource-server-mode request
validation (terraform/agentic-iam.tf's `vault_oauth_resource_server_config_profile`)
actually enforces RAR constraints on a bare Bearer token -- as opposed to
only mattering inside a real OAuth/OBO exchange. This is the empirical
question scripts/dev/configure_agentic_iam.sh exists to answer; nothing in
HashiCorp's docs confirms it either way for a non-OBO request.

Reuses the same throwaway signing key as mint_fake_svid.py, registered as
`terraform/agentic-iam.tf`'s "spire" OAuth resource server profile's
public_keys. This is NOT a SPIFFE JWT-SVID (no `aud: vault` SPIFFE-login
shape) -- it's shaped like what the "spire" profile's `issuer_id` /
`user_claim` expect.

Usage: python3 mint_rar_jwt.py --capabilities read --path kv/data/test-secret
"""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import jwt

from mint_fake_svid import SPIFFE_ID, TRUST_DOMAIN, ensure_keypair

HERE = Path(__file__).parent
OUT_DIR = HERE / "svids"


def mint(path: str, capabilities: list[str], ttl_seconds: int) -> Path:
    priv_path, _pub_path = ensure_keypair()
    private_key = priv_path.read_text()

    now = int(time.time())
    claims = {
        "sub": SPIFFE_ID,
        "aud": "vault",
        "iat": now,
        "exp": now + ttl_seconds,
        "authorization_details": [
            {"type": "vault:path_access", "path": path, "capabilities": capabilities}
        ],
    }
    token = jwt.encode(claims, private_key, algorithm="RS256", headers={"kid": "spire-key-0"})

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out = OUT_DIR / "rar_jwt.token"
    out.write_text(token)
    print(f"wrote RAR-bearing JWT to {out}")
    print(f"  sub: {SPIFFE_ID}")
    print(f"  authorization_details: {json.dumps(claims['authorization_details'])}")
    print(f"  (issuer_id this must match in Vault's profile: spiffe://{TRUST_DOMAIN})")
    return out


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--path", default="kv/data/test-secret")
    parser.add_argument("--capabilities", nargs="+", default=["read"])
    parser.add_argument("--ttl", type=int, default=300)
    args = parser.parse_args()
    mint(args.path, args.capabilities, args.ttl)
