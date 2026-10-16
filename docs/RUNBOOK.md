# Runbook

## Provisioning order, and why it's fixed

SPIRE needs the EKS cluster to exist before it can run. Vault's SPIFFE config needs SPIRE's
JWKS bundle before it can be applied. So provisioning is five phases, not one `terraform
apply`:

1. **AWS infra + HCP Vault cluster** -- VPC, EKS, RDS, HVN, HVN↔VPC peering, the Vault
   Dedicated cluster itself. No Vault *config* yet.
2. **SPIRE on the new cluster** (Helm), then `scripts/refresh-bundle.sh` pulls its JWKS
   bundle out so Vault can validate against it statically (see "Why a static bundle" below).
3. **Full `terraform apply`** -- now `vault-config.tf`'s `file(var.spiffe_bundle_jwks_path)`
   can actually read something.
4. **Build + push images, deploy the app manifests.**
5. **`scripts/02-configure-vault.sh`** (the one imperative step -- root rotation) and
   **`scripts/03-verify.sh`** (the go/no-go gate).

`scripts/01-provision.sh` runs all five. **This has not been executed end to end against real
AWS/HCP** -- both credentials were expired in the environment this was built in. Every
Terraform file passed `terraform validate`; every k8s manifest passed `kubeconform -strict`;
none of it has seen a real `terraform apply` or `kubectl apply`. Re-authenticate
(`aws sso login`, `hcp auth login`), then run it and fix forward from whatever breaks first.

## The one unresolved risk: does HCP Vault Dedicated expose `auth/spiffe`?

Vault's native SPIFFE auth method (`auth/spiffe`, Vault **consumes** SPIRE's SVIDs) is
Enterprise-licensed, GA in Vault 1.21. HCP Vault Dedicated runs Vault 2.x, so it's in version
range. But the only SPIFFE-related entry in the HCP changelog describes the SPIFFE **secrets
engine** (Vault **issues** JWT-SVIDs) -- the opposite direction from what this demo needs. No
documentation confirms `auth/spiffe` availability on Dedicated either way.

Because HCP Vault Dedicated *is* Vault Enterprise, there's no separate license to buy here --
availability is HashiCorp's call on this tier. `scripts/03-verify.sh` probes it directly
(`vault auth enable spiffe`). Everything in this repo defaults to the **`auth/jwt` fallback**,
which was validated locally end to end (see below) and tells an identical story:
`user_claim=sub` still puts the full SPIFFE ID in the audit log. If the probe succeeds, set
`-var=spiffe_auth_available=true` and re-apply `terraform/vault-config.tf`.

## Why a static trust bundle, not an OIDC endpoint

`auth/spiffe` and `auth/jwt` can both validate against a live OIDC discovery endpoint. For
HCP Vault reaching an endpoint *inside* the EKS cluster, that needs an internal load balancer,
HVN↔VPC peering, security group rules, and (per HCP's own docs) likely a Route 53 inbound
resolver + HCP private DNS forwarding so the HVN can resolve the private name. Four fragile,
slow-to-iterate pieces.

A **static JWKS bundle** (`profile="static"` / `jwt_validation_pubkeys`) needs none of that --
Vault validates offline against keys baked in at provision time. The trade: SPIRE's signing
keys are bounded by `ca_ttl` (default 24h) and a new key is appended on every server restart,
so a static bundle **goes stale within ~24h**. Correct trade for a stack provisioned fresh and
torn down after each rehearsal (`scripts/destroy.sh`); run `scripts/refresh-bundle.sh` again if
the stack outlives a day.

HVN↔VPC peering is still required for Vault to reach RDS (the database secrets engine) --
that part doesn't go away.

## Validated locally (docker-compose, before touching cloud)

All three beats ran end to end against a real Vault dev server + real PostgreSQL, SPIFFE
simulated with a hand-signed JWT (`scripts/dev/mint_fake_svid.py`) since there's no SPIRE
deployment in a laptop-only environment, and a real Vault file audit device. This caught
concrete bugs, now fixed in code -- treat these as warnings if you ever touch the relevant
files:

- **`sys/leases/revoke` and `auth/token/create` are not implied by database-read access.**
  The policy needs its own explicit grant for both, or beat 2's revoke and beat 3's
  approval-child-token both fail with `hvac.exceptions.Forbidden`.
- **hvac's `Token.create()` takes `meta=`, not `metadata=`.** Confirmed via
  `inspect.signature(hvac.api.auth_methods.token.Token.create)`.
- **Vault token `display_name` sanitizes `:` and `/` into `-`.** A SPIFFE ID in
  `display_name` renders as `spiffe---nimbus-demo-ns-...` -- recognizable, not exact. Use
  `auth.metadata` for anything that needs to be literal (a slide, a query result).
- **`claim_mappings=sub=spiffe_id` on the `auth/jwt` role** puts the full, unmangled SPIFFE ID
  in `auth.metadata.spiffe_id` on every request through that role -- the reliable field.
- **A human-approved action's child token (`auth/token/create`) does not inherit the parent's
  identity.** Without deliberately copying `spiffe_id` into the child's `meta` and setting its
  `display_name` (see `vault.py`'s `VaultSession.get_db_credentials`), the audit entry for an
  approved refund shows only the approval fields and a generic "token-token" -- losing the
  "which workload" half of beat 3's claim.
- **Confirmed end to end**: one audit record for `database/creds/refund-writer` carrying
  `auth.metadata = {approval_id, approved_by, spiffe_id}` -- beat 3's exact claim, proven
  against a real audit log entry, not asserted.
- **An agent's in-memory credential cache does not know about out-of-band revocations.**
  `scripts/reset.sh` calls `vault lease revoke -prefix database/creds/` directly; without also
  calling the agent's `/vault/forget` (wired to `scripts/reset.sh` via the storefront's
  `/api/admin/forget`), the next request keeps trying the now-dead lease and fails with a
  confusing PostgreSQL password-auth error instead of cleanly re-minting.
- Vault's Identity **entity alias** (`user_claim=sub`) durably binds the SPIFFE ID to an
  `entity_id` independent of any one token -- a second, corroborating identity signal
  (`vault read identity/entity/id/<id>`) if `auth.metadata` ever comes up empty.

`scripts/dev/configure_local_vault.sh` reproduces the Vault-side config this way;
`terraform/vault-config.tf` carries the same fixes forward for the real stack.

## Agentic IAM (optional, Enterprise, entirely unverified by execution)

HashiCorp's **Agentic IAM** (Agent Registry, Vault as an OAuth resource server, RFC 9396 Rich
Authorization Requests) is GA in Vault Enterprise 2.1 (2026-09-01) -- this repo's name echoes
it. `terraform/agentic-iam.tf` registers the secure agent and enforces a per-request RAR
constraint, gated behind `var.agentic_iam_available` (default `false`).

**Why this is the least-verified part of the whole repo.** Every other optional branch here
(`auth/spiffe`, native SPIFFE) could at least be *attempted* against infrastructure available
while building it. This one could not be attempted at all:

- **Vault Enterprise's own dev-mode binary refuses to start without a real license.**
  Confirmed by direct test: `docker run hashicorp/vault-enterprise` fails immediately with
  `Error initializing core: license check failed: no autoloaded license provided.` There is no
  auto-generated evaluation license baked into the binary.
- **That license is sales/support-gated, not self-serve.** The error message points to
  `https://vaultproject.io/trial`, which redirects to a HashiCorp tutorial page whose only
  instruction is *"your customer support contact can generate a trial license."* No instant
  download form was found.
- **True on-behalf-of (OBO) human delegation is doubly blocked even with a license.** It needs
  `actor_claim` on the OAuth resource server profile, which the Terraform provider documents
  as requiring **Vault 2.2.0+** -- only at `rc1` as of this writing, not GA (latest GA is
  2.1.2). And among HashiCorp's documented IdP integrations, only **IBM Verify** has a real
  RFC 8693 token-exchange example with `act`/`may_act` claims -- Auth0's documented path is a
  plain `authorization_code` + PAR/RAR flow, **not** real OBO, and Auth0's RAR/PAR support
  itself requires an **Enterprise-tier Auth0 tenant** (not self-serve either). Both of these
  are why `agentic-iam.tf` deliberately does not attempt OBO at all.
- **Whether HCP Vault Dedicated exposes any of this is unconfirmed.** The docs carry a generic
  `"Vault Enterprise license or HCP Vault Dedicated cluster required"` banner, but the real
  HCP Vault Dedicated changelog has zero mentions of "Agent Registry," "OAuth resource server,"
  or "RAR" as of this writing, and both `agent-registry/...` (root-mounted) and
  `sys/config/oauth-resource-server/...` (a `sys/`-level path) sit exactly where HCP's
  no-root-namespace policy would plausibly block them. `scripts/04-verify-agentic-iam.sh`
  probes this directly -- treat it as "almost certainly fails," not "probably works."

**What's scoped in, and why it's still worth building:** Agent Registry registration + a
ceiling policy + RAR enforcement via a self-issued JWT, with no external IdP at all --
`sys/config/oauth-resource-server` doesn't require a classic consumer IdP, only a signer and a
JWKS/public key set, which SPIRE already is. This is genuinely testable the moment a trial
license exists, with no second sales conversation needed.

**Local test path, once you have a trial license:**
```bash
export VAULT_LICENSE="<your license string>"
docker compose --profile enterprise up -d vault-enterprise
bash scripts/dev/configure_agentic_iam.sh
```
That script registers the agent, configures the OAuth resource server profile against a
throwaway SPIRE-shaped key, and runs the one real experiment this repo couldn't run before:
presents a bare Bearer JWT carrying `authorization_details` directly to a KV path, with two
deliberately-wrong variants (wrong path, wrong capability), to find out empirically whether
RAR is enforced outside a real OAuth/OBO exchange. **Record the actual HTTP codes it prints**
in this file -- update this section once you know, rather than leaving it a hypothesis.

If both `03-verify.sh`-equivalent confirmation and `04-verify-agentic-iam.sh` pass against the
real HCP cluster, re-apply with `-var=agentic_iam_available=true`. If not: this doesn't block
anything else here -- beats 1 through 3 and the whole verification checklist below stand
entirely on their own without Agentic IAM.

## HCP Vault Dedicated constraints that shape this build

- **Most authenticated `/v1/sys` endpoints are blocked.** Exceptions: `/sys/leader`,
  `/sys/metrics`, `/sys/seal-status`. `vault audit enable` is **not** available -- audit comes
  via log streaming (one destination at a time) or a portal download with a 1-hour window and
  a 10-minute download link. For the talk, pre-save a CloudWatch Logs Insights query and
  **measure the ingestion lag in rehearsal** -- this script cannot check that for you.
- Root namespace is HashiCorp's; every `vault` CLI call here runs with `VAULT_NAMESPACE=admin`.
- Admin token TTL is **6 hours** -- regenerate it right before walking on stage.
- Development tier has **no audit log access at all**; the cheapest tier that supports this
  demo's audit beat is Essentials Small (~$1,152/mo, or ~13 days on the $500 HCP trial
  credit). Don't provision Development and expect beat 3 to work.
- `HVN↔VPC` peering is plain peering, no Transit Gateway needed. **PrivateLink is
  inbound-only** and cannot help Vault reach anything in the VPC.

## Cost and cleanup

Roughly **$1.80/hr** while running (HCP Essentials Small $1.578/hr + EKS control plane
~$0.10/hr + two small nodes + RDS `db.t4g.micro`) -- about **$43/day**. The HCP trial credit
covers the Vault portion for about 13 days; AWS is billed normally regardless.

**Run `scripts/destroy.sh` after every rehearsal.** It confirms via `aws eks list-clusters`
and `aws rds describe-db-instances` that nothing AWS-side survived; the HCP portal has no
equivalent CLI check, so check it by hand too.

Unconfirmed billing detail: whether HCP's $72.92/month-per-client charge prorates for a
cluster that only lives a day or two. Check an actual invoice before assuming it doesn't.

## Verification checklist

1. `scripts/03-verify.sh` passes.
2. `vault read database/creds/refund-writer` by hand returns a credential; it can `SELECT`
   `orders` and `INSERT` into `refunds`, and is refused on `customers`; `vault lease revoke`
   kills it and removes the role from `pg_roles`.
3. `kubectl exec` into `agent-secure` shows no secret material beyond the SVID file, and the
   decoded SVID's `sub` matches the SPIRE `ClusterSPIFFEID`'s template.
4. **Negative test**: run the agent from a different service account (or delete the
   `ClusterSPIFFEID`) and confirm `auth/jwt/login` (or `auth/spiffe/login`) is refused --
   proves identity is enforced, not decorative.
5. `scripts/demo-beat{1,2,3}.sh` run clean back to back, twice in a row, with
   `scripts/reset.sh` between runs -- validated locally; re-confirm against the real cluster.
6. `scripts/record-demo.sh` produces the fallback video.
7. `scripts/destroy.sh` leaves nothing billable.
