#!/usr/bin/env python3
"""LOCAL DEV ONLY. Mints a JWT shaped like a SPIFFE JWT-SVID, signed with a
throwaway RSA key, so `agent-secure` has something to present to Vault's
`auth/jwt` backend without a real SPIRE deployment.

This is not part of the stage demo -- on EKS, `spiffe-helper` writes a real
JWT-SVID signed by SPIRE, verified by Vault against SPIRE's own JWKS/static
bundle. This script exists purely so `vault.py`'s JWT-login and
dynamic-credential code paths can be exercised end to end on a laptop.

Usage: python3 mint_fake_svid.py [--ttl 300]
"""
from __future__ import annotations

import argparse
import time
from pathlib import Path

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

HERE = Path(__file__).parent
KEYS_DIR = HERE / "keys"
SVIDS_DIR = HERE / "svids"

TRUST_DOMAIN = "nimbus.demo"
SPIFFE_ID = f"spiffe://{TRUST_DOMAIN}/ns/agents/sa/ai-support-agent-secure"
AUDIENCE = "vault"


def ensure_keypair() -> tuple[Path, Path]:
    priv_path = KEYS_DIR / "fake_spire_key.pem"
    pub_path = KEYS_DIR / "fake_spire_key.pub.pem"
    if priv_path.exists() and pub_path.exists():
        return priv_path, pub_path

    KEYS_DIR.mkdir(parents=True, exist_ok=True)
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
    print(f"generated throwaway keypair at {KEYS_DIR}")
    return priv_path, pub_path


def mint(ttl_seconds: int) -> Path:
    priv_path, _pub_path = ensure_keypair()
    private_key = priv_path.read_text()

    now = int(time.time())
    claims = {
        "sub": SPIFFE_ID,
        "aud": AUDIENCE,
        "iat": now,
        "exp": now + ttl_seconds,
    }
    token = jwt.encode(claims, private_key, algorithm="RS256")

    SVIDS_DIR.mkdir(parents=True, exist_ok=True)
    out = SVIDS_DIR / "jwt_svid.token"
    out.write_text(token)
    print(f"wrote fake SVID (sub={SPIFFE_ID}, ttl={ttl_seconds}s) to {out}")
    return out


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--ttl", type=int, default=300)
    args = parser.parse_args()
    mint(args.ttl)
