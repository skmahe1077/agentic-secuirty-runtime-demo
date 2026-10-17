# agentic-security-runtime-demo

A live-runnable demo for the talk **"No Standing Access for AI Agents with Vault Runtime
Security and SPIFFE."** A small shopping site, **Mahi Stores**, has an AI customer-support
agent that issues refunds. Two versions of that agent run side by side:

- **`agent-insecure`** -- a static, long-lived database password. Standing access: the
  credential belongs to the app, not the task, and has no idea who's asking.
- **`agent-secure`** -- a real SPIFFE workload identity (SPIRE-issued) exchanged for a Vault
  token via the native `auth/spiffe` method, which mints a database credential scoped to one
  role with a 3-minute TTL, used once, then dead on command.

A third beat shows a human approving a large refund; the storefront's **Control Room** panel
-- a live, dark stage-column diagram (Identity → Authenticate → Approval → Credential →
Execute), driven entirely by the agents' own real events -- shows both registered agents side
by side with their real Vault Agent Registry ceiling policy, and correlates the approver's
name, the workload's SPIFFE ID, and the Vault lease in the Credential stage's detail drawer.
(Vault's own audit log carries the identical three fields -- enabled and verified by
`scripts/03-verify.sh`, but presenter-only, not shown on stage.)

A fourth beat demonstrates the real **Vault Agentic IAM** feature this repo is named after
(Agent Registry + RAR) -- no longer gated behind a hypothetical license: this stack runs
self-managed Vault Enterprise on EKS with a real trial license, so `terraform/agentic-iam.tf`
applies unconditionally. See "Agentic IAM" below and `docs/RUNBOOK.md`.

The demo is **presenter-driven**: the audience watches a live, publicly reachable website on
screen (storefront + chatbot + real refund flow), not a terminal. They do not open the URL
themselves.

## Architecture

```mermaid
flowchart TB
    Audience["🎤 Audience<br/>watches on screen"] --> Browser["Browser"]
    Browser -->|"HTTPS, IP-allowlisted"| ALB["AWS ALB<br/>internet-facing"]

    subgraph EKS["EKS cluster"]
        subgraph nsNimbus["namespace: nimbus"]
            Storefront["storefront (FastAPI)<br/>_resolve() routes 'secure' mode"]
            AgentInsecure["agent-insecure<br/>static DB password"]
        end

        subgraph nsAgents["namespace: agents"]
            OrderAgent["order-agent<br/>SPIFFE identity, read-only"]
            RefundAgent["refund-agent (agent-secure)<br/>SPIFFE identity, can refund"]
        end

        subgraph nsSpire["namespace: spire-mgmt"]
            Spire["SPIRE server + agent"]
        end

        subgraph nsVault["namespace: vault"]
            Vault["Vault Enterprise<br/>Raft + AWS KMS auto-unseal"]
        end
    end

    RDS[("AWS RDS Postgres<br/>orders · refunds · customers · products")]

    ALB --> Storefront
    Storefront -->|"agent=insecure"| AgentInsecure
    Storefront -->|"agent=secure, default"| OrderAgent
    Storefront -->|"agent=secure, refund wording"| RefundAgent

    Spire -.->|issues SVID| OrderAgent
    Spire -.->|issues SVID| RefundAgent

    AgentInsecure -->|static password, no scoping| RDS
    OrderAgent -->|"auth/spiffe login"| Vault
    RefundAgent -->|"auth/spiffe login"| Vault
    Vault -->|"mints scoped, TTL'd credential<br/>(order-reader / refund-writer)"| RDS
```

`order-agent` and `refund-agent` are genuinely separate SPIFFE identities and Vault-scoped DB
roles -- not one identity with a UI toggle. The storefront decides which one handles a "secure"
request automatically (least-privilege by default); see "Agentic IAM" below.

## Storefront UI

Two tabs, switched in the topbar:

- **Shop** (default) -- a clean consumer storefront: a 14-item product catalog with real photos
  (`app/storefront/static/images/`, sourced from Wikimedia Commons and bundled locally --
  nothing hotlinked, so nothing can fail to load on venue Wi-Fi), including four Apple-branded
  items (iPhone 18 Pro, MacBook Air, AirPods Pro, Apple Watch -- demo catalog labels, not
  verified real current products; see `images/ATTRIBUTION.md`). A floating **💬 AI Assistant**
  chat widget (with its own "Chatting as" customer picker and "Support agent" mode picker, both
  kept in sync with the Control Room tab's) is collapsed to a launcher by default. Clicking a
  suggestion chip ("Request a refund" / "Check my order status") without an order number asks
  for one via a real follow-up turn, not a canned error. No other demo chrome visible -- a real
  shopper never sees a security panel.
- **Control Room** -- the presenter/demo view: the "Shopping as" and "Support agent" controls
  (switch customer, switch insecure/secure mode), an **Order History** table (who ordered what,
  with the order number -- reuses `/api/orders`, for picking a valid customer/order combo live),
  and a live, dark stage-column diagram (Identity → Authenticate → Approval → Credential →
  Execute). Identity shows **both** registered agents (`order-agent`, `refund-agent`) at once --
  kept live via `/api/state` polling, not just whichever handled the last turn -- each tagged
  with its real Agent Registry ceiling policy. Real SVG connector lines link every card to the
  next (both agents converge into Authenticate), a dashed bypass arc appears when a refund skips
  Approval (under the £100 threshold), and a dark terminal-style event stream replaces the old
  Activity log.

The chat widget talks to whichever backend `app/storefront/main.py`'s `_resolve()` routes to --
see "Agentic IAM" below for what that means once two agents exist.

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

With a real Enterprise license on a real cluster, `terraform/agentic-iam.tf` registers **two**
agents and applies unconditionally as part of `scripts/01-provision.sh`:

- **`order-agent`** -- read-only, cannot issue refunds (PostgreSQL has no grant for it to).
- **`refund-agent`** -- can look up orders and issue refunds.

The customer never picks between them; `app/storefront/main.py` routes "secure" mode to
whichever one fits the request automatically, defaulting to the read-only one. See
`scripts/demo-beat4-agentic-iam.sh` for the live version of the contrast.

To re-run just the verification, the RAR empirical test, and a ceiling-misconfiguration probe
on an existing stack:

```bash
bash scripts/04-verify-agentic-iam.sh
```

That script confirms both Agent Registry registrations and the OAuth resource server path are
reachable, then runs two real experiments -- both now empirically answered on a real cluster,
not open questions:

- A bare Bearer JWT carrying `authorization_details`, presented directly to a KV path outside
  any real OAuth/OBO exchange, is refused identically (HTTP 403) whether its claimed
  path/capability are right or wrong. RAR isn't enforced on this path without a real OBO flow.
- Deliberately widening `order-agent`'s real ACL policy to also grant `refund-writer` read
  access, then asking for it with a normal `auth/spiffe`-issued token (not a bare Bearer JWT),
  **succeeds** -- the Agent Registry ceiling did not block it. The ceiling constrains an
  OBO/RAR-delegated request, not an agent's own ordinary token.

See `docs/RUNBOOK.md`'s "Agentic IAM" section for the full detail, and why real on-behalf-of
delegation (a different, human-approval-linking piece) isn't attempted at all.

## Layout

| Path | What's there |
|---|---|
| `app/storefront/` | FastAPI storefront: Shop/Control Room tabs, catalog with local product photos, floating AI Assistant chat widget, the live Control Room panel + order history |
| `app/agent/` | The support agent, as one image running in two modes (`AGENT_MODE=insecure\|secure`) |
| `app/db/` | Schema + seed data + the deliberately-bad `nimbus_app_legacy` role + the storefront's own least-privilege role |
| `terraform/` | AWS (VPC/EKS/RDS/KMS) + self-managed Vault Enterprise (vault-helm) + AWS Load Balancer Controller + Vault config + Agentic IAM |
| `k8s_manifests/` | SPIRE Helm values, storefront/agent Deployments (`agent-insecure`, `agent-secure` = refund-agent, `order-agent`), the public storefront Ingress |
| `scripts/` | Provisioning, Vault init, the go/no-go gates, the four demo beats, reset, teardown |
| `docs/RUNBOOK.md` | Provisioning order, self-managed-Vault constraints, confirmed gotchas, cost |
| `docs/TALK-NOTES.md` | The four-beat narrative script, stagecraft notes, prior art to cite |

## Open risks

- The storefront exposes unauthenticated `/api/admin/reset` and `/api/admin/revoke` endpoints
  (both buttons in the UI). The demo relies on the ALB's security-group IP allowlist, not
  application auth, to keep them presenter-only -- see `docs/RUNBOOK.md`.
- `scripts/01-provision.sh` has now been run successfully end-to-end against real AWS -- see
  `docs/RUNBOOK.md`'s "Confirmed gotchas from the first real provisioning run" for the real bugs
  that surfaced and were fixed (EKS addon ordering, SPIRE chart compatibility, a JWKS bundle
  that silently broke every `auth/spiffe` login, and others). Read that section before the next
  from-scratch provision.
- In-cluster Vault traffic is unencrypted (`global.tlsDisable = true`) -- correct for this demo,
  not for production. See `docs/TALK-NOTES.md`'s "what's not real here."
