# agentic-security-runtime-demo

A live-runnable demo for the talk **"No Standing Access for AI Agents with Vault Runtime
Security and SPIFFE."** A small shopping site, **Nimbus Store**, has an AI customer-support
agent that issues refunds. Two versions of that agent run side by side:

- **`agent-insecure`** -- a static, long-lived database password. Standing access: the
  credential belongs to the app, not the task, and has no idea who's asking.
- **`agent-secure`** -- a real SPIFFE workload identity (SPIRE-issued) exchanged for a Vault
  token via the native `auth/spiffe` method, which mints a database credential scoped to one
  role with a 3-minute TTL, used once, then dead on command.

A third beat shows a human approving a large refund; the storefront's **Identity & Access
panel** correlates the approver's name, the workload's SPIFFE ID, and the Vault lease on one
card. (Vault's own audit log carries the identical three fields -- enabled and verified by
`scripts/03-verify.sh`, but presenter-only, not shown on stage.)

A fourth beat demonstrates the real **Vault Agentic IAM** feature this repo is named after
(Agent Registry + RAR) -- no longer gated behind a hypothetical license: this stack runs
self-managed Vault Enterprise on EKS with a real trial license, so `terraform/agentic-iam.tf`
applies unconditionally. See "Agentic IAM" below and `docs/RUNBOOK.md`.

The demo is **presenter-driven**: the audience watches a live, publicly reachable website on
screen (storefront + chatbot + real refund flow), not a terminal. They do not open the URL
themselves.

## Quick start (local, no cloud) -- offline UI development only

```bash
docker compose up -d --build
open http://localhost:8000          # the storefront
bash scripts/demo-beat1.sh          # standing access is the problem
bash scripts/reset.sh               # back to a clean state
```

This trimmed local stack (Postgres + storefront + `agent-insecure`) is for iterating on the
storefront UI and running beat 1 without any cloud account. **It cannot run beats 2, 3, or 4**
-- there is no SPIRE here and no Vault, so `agent-secure` has nothing to authenticate with.
Vault Enterprise also needs a real license to even start, so there was never a zero-config
local option for the secure path. Beats 2-4 are EKS-only; see below.

## The real thing: AWS EKS + self-managed Vault Enterprise + SPIRE

**Prerequisites:**
1. A Vault Enterprise trial license, stored in AWS Secrets Manager:
   ```bash
   aws secretsmanager create-secret --name agentic-sec-demo/vault-license \
     --secret-string "$(cat vault.hclic)"
   ```
2. `app/db/04_storefront_role.sql` and `app/db/03_legacy_role.sql` applied once by hand against
   RDS (after the first `terraform apply`'s RDS instance exists).

```bash
export IMAGE_REGISTRY=<your ECR repo>
export LEGACY_DB_PASSWORD=<see app/db/03_legacy_role.sql>
export STOREFRONT_DB_PASSWORD=<see app/db/04_storefront_role.sql>
bash scripts/01-provision.sh
```

**Read `docs/RUNBOOK.md` before running this.** `scripts/03-verify.sh` and
`scripts/04-verify-agentic-iam.sh` are go/no-go gates; don't build a rehearsal on top of a
stack that hasn't passed them.

**This stack costs real money while it's up** -- see `docs/RUNBOOK.md`'s cost math (well under
the HCP-based version's ~$1.80/hr). Run `scripts/destroy.sh` after every rehearsal -- it
explicitly checks for orphaned load balancers and EBS volumes, the two new leak modes this
migration introduced.

## Agentic IAM (Agent Registry + RAR)

With a real Enterprise license on a real cluster, `terraform/agentic-iam.tf` applies
unconditionally as part of `scripts/01-provision.sh`. To re-run just its verification and the
RAR empirical test on an existing stack:

```bash
bash scripts/04-verify-agentic-iam.sh
```

That script confirms the Agent Registry and OAuth resource server paths are reachable, then
runs the one real experiment this repo exists to answer: presents a bare Bearer JWT carrying
`authorization_details` directly to a KV path, with two deliberately-wrong variants (wrong
path, wrong capability), to find out empirically whether RAR is enforced outside a real
OAuth/OBO exchange -- something nothing in HashiCorp's docs confirms either way. See
`docs/RUNBOOK.md`'s "Agentic IAM" section for what's confirmed, and why real on-behalf-of
delegation (a different, human-approval-linking piece) isn't attempted at all.

## Layout

| Path | What's there |
|---|---|
| `app/storefront/` | FastAPI storefront: catalog, orders, support chat, the Identity & Access panel |
| `app/agent/` | The support agent, as one image running in two modes (`AGENT_MODE=insecure\|secure`) |
| `app/db/` | Schema + seed data + the deliberately-bad `nimbus_app_legacy` role + the storefront's own least-privilege role |
| `terraform/` | AWS (VPC/EKS/RDS/KMS) + self-managed Vault Enterprise (vault-helm) + AWS Load Balancer Controller + Vault config + Agentic IAM |
| `k8s_manifests/` | SPIRE Helm values, storefront/agent Deployments, the public storefront Ingress |
| `scripts/` | Provisioning, Vault init, the go/no-go gates, the three demo beats, reset, teardown |
| `docs/RUNBOOK.md` | Provisioning order, self-managed-Vault constraints, confirmed gotchas, cost |
| `docs/TALK-NOTES.md` | The four-beat narrative script, stagecraft notes, prior art to cite |

## Open risks

- The storefront exposes unauthenticated `/api/admin/reset` and `/api/admin/revoke` endpoints
  (both buttons in the UI). The demo relies on the ALB's security-group IP allowlist, not
  application auth, to keep them presenter-only -- see `docs/RUNBOOK.md`.
- A handful of chart/image specifics (the `vault-helm` version, the `hashicorp/vault-enterprise`
  image tag, the AWS Load Balancer Controller chart version) are pinned to values that were not
  confirmed against a live `helm search repo` at the time this was written -- confirm before the
  first apply; `terraform init` fails loudly and immediately if any are wrong.
- In-cluster Vault traffic is unencrypted (`global.tlsDisable = true`) -- correct for this demo,
  not for production. See `docs/TALK-NOTES.md`'s "what's not real here."
