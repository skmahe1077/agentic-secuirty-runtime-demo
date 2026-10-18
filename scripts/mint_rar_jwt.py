#!/usr/bin/env python3
"""Mints a JWT carrying an RFC 9396 `authorization_details` claim, to test
whether Vault's OAuth-resource-server-mode request validation
(terraform/agentic-iam.tf's `vault_oauth_resource_server_config_profile`)
actually enforces RAR constraints on a bare Bearer token -- as opposed to
only mattering inside a real OAuth/OBO exchange. This is the empirical
question scripts/04-verify-agentic-iam.sh exists to answer; nothing in
HashiCorp's docs confirms it either way for a non-OBO request.

Self-contained: signs with its own throwaway RSA key (not SPIRE's real
signing key -- the OAuth resource server profile is configured with its
own `public_keys` from scripts/refresh-bundle.sh's output specifically so
a throwaway key registered there can be tested against). This is NOT a
SPIFFE JWT-SVID (no `aud: vault` SPIFFE-login shape) -- it's shaped like
what the "spire" profile's `issuer_id` / `user_claim` expect.

Usage: python3 scripts/mint_rar_jwt.py --capabilities read --path kv/data/test-secret --out /tmp/rar.jwt

Also doubles as the OBO-shaped minter for scripts/05-verify-obo.sh: pass
--actor-sub to add an `act.sub` claim + an auto `jti` (both omitted by
default, which is what reproduces the original bare-Bearer finding in
docs/RUNBOOK.md -- that token had neither, against a profile whose
`actor_claim`/`unique_id_claim` default server-side to `act.sub`/`jti`).
--sub overrides who the token is *about* (the human, for a real OBO
token); --issuer/--kid let it target a different oauth-resource-server
profile than the original "rar-probe" one.
"""
from __future__ import annotations

import argparse
import json
import time
import uuid
from pathlib import Path

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

TRUST_DOMAIN = "nimbus.demo"
SPIFFE_ID = f"spiffe://{TRUST_DOMAIN}/ns/agents/sa/ai-support-agent-secure"
# A distinct issuer from the real "spire" profile's issuer_id
# (spiffe://nimbus.demo) -- Vault picks which configured OAuth
# resource-server profile to validate a bare Bearer token against by its
# `iss` claim, and two profiles can't share an issuer_id. This JWT is
# deliberately not a real SPIFFE JWT-SVID (see module docstring), so it
# gets its own throwaway issuer rather than colliding with the real one.
RAR_PROBE_ISSUER = f"spiffe://{TRUST_DOMAIN}/rar-probe"


def ensure_keypair(keys_dir: Path) -> tuple[Path, Path]:
    priv_path = keys_dir / "rar_probe_key.pem"
    pub_path = keys_dir / "rar_probe_key.pub.pem"
    if priv_path.exists() and pub_path.exists():
        return priv_path, pub_path

    keys_dir.mkdir(parents=True, exist_ok=True)
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    priv_path.write_bytes(
        key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
    )
    pub_path.write_bytes(
        key.public_key().public_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PublicFormat.SubjectPublicKeyInfo,
        )
    )
    print(f"generated throwaway RAR-probe keypair at {keys_dir}")
    return priv_path, pub_path


def mint(
    path: str,
    capabilities: list[str],
    ttl_seconds: int,
    out_path: Path,
    keys_dir: Path,
    sub: str = SPIFFE_ID,
    actor_sub: str | None = None,
    issuer: str = RAR_PROBE_ISSUER,
    kid: str = "rar-probe-key-0",
) -> Path:
    priv_path, pub_path = ensure_keypair(keys_dir)
    private_key = priv_path.read_text()

    now = int(time.time())
    claims = {
        "iss": issuer,
        "sub": sub,
        "aud": "vault",
        "iat": now,
        "exp": now + ttl_seconds,
        "authorization_details": [
            {"type": "vault:path_access", "path": path, "capabilities": capabilities}
        ],
    }
    # Deliberately opt-in, not default: a token with no `act`/`jti` is
    # exactly what reproduces the original (misleading) bare-Bearer
    # finding -- see module docstring and scripts/05-verify-obo.sh's T4.
    if actor_sub:
        claims["act"] = {"sub": actor_sub}
        claims["jti"] = str(uuid.uuid4())
    token = jwt.encode(claims, private_key, algorithm="RS256", headers={"kid": kid})

    out_path.write_text(token)
    print(f"wrote RAR-bearing JWT to {out_path}")
    print(f"  sub: {sub}" + (f" / act.sub: {actor_sub}" if actor_sub else " (no act claim)"))
    print(f"  authorization_details: {json.dumps(claims['authorization_details'])}")
    print(f"  signing public key (register this in the probe's oauth-resource-server profile): {pub_path}")
    return out_path


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--path", default="kv/data/test-secret")
    parser.add_argument("--capabilities", nargs="+", default=["read"])
    parser.add_argument("--ttl", type=int, default=300)
    parser.add_argument("--out", default="/tmp/rar_jwt.token")
    parser.add_argument("--keys-dir", default="/tmp/rar-probe-keys")
    parser.add_argument("--sub", default=SPIFFE_ID, help="the `sub` claim -- who the token is about")
    parser.add_argument("--actor-sub", default=None, help="if set, adds `act.sub` + an auto `jti` (opt-in; see module docstring)")
    parser.add_argument("--issuer", default=RAR_PROBE_ISSUER)
    parser.add_argument("--kid", default="rar-probe-key-0")
    args = parser.parse_args()
    mint(
        args.path, args.capabilities, args.ttl, Path(args.out), Path(args.keys_dir),
        sub=args.sub, actor_sub=args.actor_sub, issuer=args.issuer, kid=args.kid,
    )
