# agentic-security-runtime-demo

A live-runnable demo for the talk **"No Standing Access for AI Agents with Vault Runtime
Security and SPIFFE."** A small shopping site, **Nimbus Store**, has an AI customer-support
agent that issues refunds. Two versions of that agent run side by side:

- **`agent-insecure`** -- a static, long-lived database password. Standing access: the
  credential belongs to the app, not the task, and has no idea who's asking.
- **`agent-secure`** -- a SPIFFE workload identity exchanged for a Vault token, which mints a
  database credential scoped to one role with a 3-minute TTL, used once, then dead on command.

A third beat shows a human approving a large refund, with Vault's own audit log carrying both
the workload's SPIFFE ID and the approver's name on the same record.

A fourth, **optional** beat attempts the real **Vault Agentic IAM** feature this repo is named
after (Agent Registry + RAR) -- gated on getting a Vault Enterprise trial license, which is
sales-gated with no instant self-serve path. See "Agentic IAM" below and
`docs/RUNBOOK.md`.

## Quick start (local, no cloud)

```bash
docker compose up -d --build
bash scripts/dev/configure_local_vault.sh   # Vault dev server: db engine, jwt auth, policy
export VAULT_ADDR=http://localhost:8200 VAULT_TOKEN=root
vault audit enable file file_path=/tmp/vault_audit.log   # optional, for beat 3's audit proof

open http://localhost:8000          # the storefront
bash scripts/demo-beat1.sh          # standing access is the problem
bash scripts/demo-beat2.sh          # SPIFFE identity + JIT credential + revoke
bash scripts/demo-beat3.sh "<your name>"   # human approval + audit trail
bash scripts/reset.sh               # back to a clean state
```

This local path uses a hand-signed JWT standing in for a real SPIFFE SVID (no SPIRE
deployment needed to iterate) -- see `scripts/dev/mint_fake_svid.py`. It is **not** part of
the real demo; it exists so the Vault/credential-lifecycle logic in `app/agent/` can be
exercised and tested without a Kubernetes cluster.

## The real thing: AWS EKS + HCP Vault Dedicated + SPIRE

```bash
export IMAGE_REGISTRY=<your ECR repo>
export LEGACY_DB_PASSWORD=<see app/db/03_legacy_role.sql>
bash scripts/01-provision.sh
```

**Read `docs/RUNBOOK.md` before running this.** In particular: the Terraform/Helm/kubectl
steps have been validated with `terraform validate` / `kubeconform`, but **not yet run against
real AWS/HCP** (both sets of credentials were expired when this was built -- see the runbook's
Phase 1). `scripts/03-verify.sh` is a go/no-go gate; don't build a rehearsal on top of a stack
that hasn't passed it.

**This stack costs real money while it's up** (~$1.80/hr -- HCP Vault Dedicated + EKS + RDS).
Run `scripts/destroy.sh` after every rehearsal.

## Agentic IAM (optional, needs a Vault Enterprise trial license)

```bash
export VAULT_LICENSE="<your trial license string>"
docker compose --profile enterprise up -d vault-enterprise
bash scripts/dev/configure_agentic_iam.sh
```

Getting the license is on you -- `https://vaultproject.io/trial` redirects to "contact your
support contact," confirmed to not be an instant self-serve form, and Vault Enterprise's own
dev-mode binary refuses to start without one (also confirmed directly). Once you have it, the
script above registers the agent, applies a ceiling policy, and empirically tests whether
Vault enforces an RFC 9396 RAR constraint on a bare Bearer token with no external IdP
involved -- something nothing in HashiCorp's docs confirms either way. See `docs/RUNBOOK.md`'s
"Agentic IAM" section for exactly what's confirmed, what's speculative, and why real
on-behalf-of delegation (a different, human-approval-linking piece) isn't attempted at all.

## Layout

| Path | What's there |
|---|---|
| `app/storefront/` | FastAPI storefront: catalog, orders, support chat, the Identity & Access panel |
| `app/agent/` | The support agent, as one image running in two modes (`AGENT_MODE=insecure\|secure`) |
| `app/db/` | Schema + seed data + the deliberately-bad `nimbus_app_legacy` role |
| `terraform/` | AWS (VPC/EKS/RDS) + HCP (HVN/Vault Dedicated) + Vault config + Agentic IAM |
| `k8s_manifests/` | SPIRE Helm values, storefront/agent Deployments |
| `scripts/` | Provisioning, the go/no-go gates, the three demo beats, reset, teardown |
| `scripts/dev/` | Local-only: fake SVID/RAR-JWT minting, local Vault config -- not part of the real demo |
| `docs/RUNBOOK.md` | Provisioning order, the SPIFFE-auth licensing risk, confirmed gotchas, cost |
| `docs/TALK-NOTES.md` | The three-beat narrative script, stagecraft notes, prior art to cite |

## The one open risk

Vault's native SPIFFE auth method (`auth/spiffe`) is Enterprise-only, GA in Vault 1.21, and
**no documentation confirms whether HCP Vault Dedicated exposes it.** `scripts/03-verify.sh`
probes this directly; everything here defaults to the `auth/jwt` fallback (validated locally
end to end) until that probe says otherwise. See `docs/RUNBOOK.md`.
