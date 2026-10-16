# Runbook

## Provisioning order, and why it's fixed

Provisioning is eight phases, not one `terraform apply`, for two independent reasons:

1. **The `kubernetes`/`helm` Terraform providers need EKS to exist first.** Their
   configuration is derived from `module.eks`'s outputs (cluster endpoint, CA cert), which are
   unknown on an empty-state plan -- Terraform cannot configure a provider from a value that
   doesn't exist yet. This is a permanent, documented property of this stack, not a bug: don't
   expect a single `terraform apply` from scratch to ever work here.
2. **Vault's root token is imperative, not a resource attribute.** With HCP Vault Dedicated,
   the admin token came from `hcp_vault_cluster_admin_token.main` -- a Terraform resource. With
   self-managed Vault, the chart creates an uninitialized, sealed Vault, and the root token only
   exists after running `vault operator init`. That has to happen between two separate
   `terraform apply`s, with the token exported as `VAULT_TOKEN` for the second one.

On top of that, SPIRE needs the EKS cluster to exist before it can run, and Vault's SPIFFE
config needs SPIRE's JWKS bundle before it can be applied.

1. **AWS base** -- `terraform apply -target=...`: VPC, EKS, RDS, the KMS unseal key, the IRSA
   roles for Vault/the EBS CSI driver/the Load Balancer Controller, and the Secrets Manager
   secret that will hold the init output. No Kubernetes or Vault resources yet.
2. **Platform charts** -- a second targeted apply: the Vault Enterprise `helm_release` and the
   AWS Load Balancer Controller `helm_release`. `vault-0` will show `0/1 Ready` -- expected,
   not a failure; `vault-helm`'s readiness probe execs `vault status`, which fails while
   uninitialized.
3. **Initialize Vault** -- `scripts/vault-init.sh` runs `vault operator init`. With AWS KMS
   auto-unseal this produces **recovery keys** (not unseal keys) plus a root token; the pod
   unseals itself and stays unsealed across restarts without human input. The token and
   recovery keys are stored in AWS Secrets Manager and in a gitignored
   `terraform/.vault-init.json`.
4. **SPIRE** -- Helm install (`spire-crds` then `spire`), then `scripts/refresh-bundle.sh`
   extracts its JWKS bundle so Vault can validate against it statically (see "Why a static
   bundle" below).
5. **Full `terraform apply`** -- now `vault-config.tf`'s `file(var.spiffe_bundle_jwks_path)`
   and `agentic-iam.tf`'s OAuth resource server `public_keys` (via `terraform/locals.tf`'s
   `fileset` over `spiffe-bundle-keys/`) can actually read something. `VAULT_ADDR`/`VAULT_TOKEN`
   from step 3 are in the environment for this apply.
6. **Build + push images, deploy the app manifests** -- including the new storefront `Ingress`.
   Then wait for the ALB to report healthy targets (2-4 minutes is normal; don't skip this and
   expect the site to be up seconds after `kubectl apply` returns).
7. **`scripts/02-configure-vault.sh`** (the one remaining imperative step -- root rotation) and
   **`scripts/03-verify.sh`** / **`scripts/04-verify-agentic-iam.sh`** (the go/no-go gates).

`scripts/01-provision.sh` runs all of the above. If Phase 3, 5, or 6 dies partway (a dropped
`kubectl port-forward`, a transient AWS API error), re-run the script -- every step is written
to be idempotent (vault-init detects an already-initialized cluster; Terraform applies are
always safe to re-run).

## Vault storage, unseal, and where the root token lives

**Raft integrated storage, 1 replica.** This is a conference-talk demo torn down and
re-provisioned daily, not production HA -- 1 replica is the deliberate choice (see
`terraform/vault-cluster.tf`'s header comment: 2 replicas would tolerate the same zero failures
as 1 while costing twice as much and adding a split-brain mode; Raft quorum arithmetic only
matters above 1 node). Auto-unseal is via AWS KMS, so a pod restart mid-rehearsal is a
non-event rather than requiring someone to type recovery keys by hand.

**`VAULT_ADDR` is a `kubectl port-forward`, not a public address.** Vault deliberately has no
ALB or NLB -- the storefront is the only thing the audience needs to reach, and a publicly
exposed, TLS-disabled Vault on a conference network is a needless risk.
`scripts/lib/common.sh`'s `vault_env()` starts the port-forward and exports
`VAULT_ADDR`/`VAULT_TOKEN`; every script that talks to Vault calls it.

**The root token never expires.** Unlike HCP's 6-hour admin token (which had to be regenerated
right before walking on stage), a self-managed root token is durable. Simpler, and the right
trade for a stack destroyed daily -- but it does mean the Secrets Manager secret and the local
`.vault-init.json` are both long-lived credentials; treat them accordingly.

**If the KMS unseal key is ever deleted**, the only way back into the cluster is the 5 recovery
keys from `vault operator init` (threshold 3-of-5), stored alongside the root token. Losing
both the key and the recovery keys means the data is unrecoverable -- for this demo, that just
means re-provisioning from scratch, which is already the normal daily workflow.

## Why a static trust bundle, not a live OIDC endpoint

`auth/spiffe` can validate against either a static JWKS bundle or a live OIDC discovery
endpoint. This repo uses the static bundle (`profile="static"` / `jwt_validation_pubkeys`):
it's already written, already understood from the HCP-era build, and the stack is torn down
daily, so there's little to gain from switching. The trade: SPIRE's signing keys are bounded
by `ca_ttl` (default 24h) and a new key is appended on every server restart, so a static bundle
**goes stale within ~24h** -- re-run `scripts/refresh-bundle.sh` (and re-apply) if the stack
outlives a day.

Now that Vault runs inside the same cluster as SPIRE (no more HCP-side network boundary),
`profile = "https_spiffe_bundle"` against SPIRE's in-cluster OIDC Discovery Provider Service is
a genuinely easy upgrade if the 24h staleness ever becomes a real problem. The chart already
installs that provider; it's just never pointed at by Vault config today.

## Confirmed gotchas (keep these fixed)

These were found the hard way during the original HCP-era local build and are still true
against the self-managed cluster -- treat as warnings if you ever touch the relevant files:

- **`sys/leases/revoke` and `auth/token/create` are not implied by database-read access.**
  The policy needs its own explicit grant for both, or beat 2's revoke and beat 3's
  approval-child-token both fail with `hvac.exceptions.Forbidden`.
- **hvac's `Token.create()` takes `meta=`, not `metadata=`.** Confirmed via
  `inspect.signature(hvac.api.auth_methods.token.Token.create)`.
- **Vault token `display_name` sanitizes `:` and `/` into `-`.** A SPIFFE ID in
  `display_name` renders as `spiffe---nimbus-demo-ns-...` -- recognizable, not exact. Use
  `auth.metadata` for anything that needs to be literal (a slide, a query result, the
  storefront's Audit correlation tile).
- **A human-approved action's child token (`auth/token/create`) does not inherit the parent's
  identity.** Without deliberately copying `spiffe_id` into the child's `meta` and setting its
  `display_name` (see `vault.py`'s `VaultSession.get_db_credentials`), the audit entry for an
  approved refund shows only the approval fields and a generic "token-token" -- losing the
  "which workload" half of beat 3's claim, and leaving the storefront's correlation tile with
  nothing to show.
- **An agent's in-memory credential cache does not know about out-of-band revocations.**
  `scripts/reset.sh` calls `vault lease revoke -prefix database/creds/` directly; without also
  calling the agent's `/vault/forget` (wired to `scripts/reset.sh` via the storefront's
  `/api/admin/forget`), the next request keeps trying the now-dead lease and fails with a
  confusing PostgreSQL password-auth error instead of cleanly re-minting.
- Vault's Identity **entity alias** durably binds the SPIFFE ID to an `entity_id` independent
  of any one token -- a second, corroborating identity signal
  (`vault read identity/entity/id/<id>`) if `auth.metadata` ever comes up empty.
- **The RDS master account and Vault's root DB account are the same account.** There is no
  separate break-glass admin (`terraform/variables.tf`'s `db_master_username` comment). After
  `scripts/02-configure-vault.sh` rotates it, only Vault knows the password -- the storefront
  uses its own dedicated `nimbus_storefront` role (`app/db/04_storefront_role.sql`) precisely
  so it doesn't go dark the moment rotation runs.

## Agentic IAM (Agent Registry + RAR) -- now real, not hypothetical

HashiCorp's **Agentic IAM** (Agent Registry, Vault as an OAuth resource server, RFC 9396 Rich
Authorization Requests) is GA in Vault Enterprise 2.1 (2026-09-01) -- this repo's name echoes
it. `terraform/agentic-iam.tf` registers the secure agent and enforces a per-request RAR
constraint, and now applies **unconditionally** -- a real trial license is installed on a real,
self-managed cluster, so there's no feature gate left.

What's still deliberately **not** attempted: real on-behalf-of (OBO) human delegation. That
needs `actor_claim` on the OAuth resource server profile, which the Terraform provider
documents as requiring Vault **2.2.0+**. `2.2.0-ent` is a published GA image as of this
writing, so the version blocker is gone -- but OBO still needs an external IdP actually capable
of RFC 8693 token exchange with `act`/`may_act` claims, and among HashiCorp's documented
providers that's only **IBM Verify** (Auth0's documented path is a plain `authorization_code` +
PAR/RAR flow, **not** real OBO, and Auth0's own RAR/PAR support needs an Enterprise-tier
tenant). Both are sales-gated products on top of an already-gated license. This stays scoped to
what needs no human-delegation identity exchange: register the agent, cap it with a ceiling
policy, enforce a per-request RAR constraint via a self-issued JWT.

**Run `scripts/04-verify-agentic-iam.sh`** to confirm the Agent Registry and OAuth resource
server paths are reachable, then run the actual empirical test: a bare Bearer JWT carrying
`authorization_details`, presented with the right path/capability and two deliberately-wrong
variants (wrong path, wrong capability). **Record the actual HTTP codes here once the script
has run** -- this was the single biggest unverified assumption in the whole repo before a real
license existed:

```
4a (right path, right capability):  HTTP ___
4b (wrong path):                    HTTP ___
4c (wrong capability):              HTTP ___
```

If 4a succeeds and 4b/4c do not, RAR enforcement on a bare Bearer token outside any OBO
exchange is real, and beat 4 can show it live. If all three behave identically, that's the
answer too -- update `terraform/agentic-iam.tf`'s comments and `docs/TALK-NOTES.md`'s beat 4
accordingly rather than leaving this section a hypothesis.

## Self-managed constraints that shape this build

These replace the HCP-era list of what HCP Vault Dedicated blocked -- self-managed Vault lifts
most of those restrictions, but introduces a different set:

- **`vault-helm`'s readiness probe forces `helm_release.vault`'s `wait = false`.** The chart's
  default readiness check execs `vault status`, which fails while Vault is uninitialized or
  sealed -- `helm install --wait` would block until timeout and roll the release back. Phase 3
  of provisioning (`scripts/vault-init.sh`) is what actually brings the pod to Ready.
- **The EBS CSI driver addon is mandatory**, not optional. Vault's data and audit PVCs use the
  default `gp2` StorageClass, which is CSI-migrated since Kubernetes 1.23 -- without the addon
  both PVCs stay `Pending` forever and the Vault pod never starts.
- **Audit storage must be enabled before enabling the audit device.** Vault treats an
  unwritable enabled audit device as a hard request failure, not a soft warning.
- **In-cluster Vault traffic is unencrypted** (`global.tlsDisable = true` in
  `terraform/vault-cluster.tf`). Deliberate and demo-only: the SVID and the Vault token travel
  in cleartext between pods, inside the VPC. Not what you'd do in production -- expect the
  question, see `docs/TALK-NOTES.md`.
- **The root token never expires** (see above) -- unlike HCP's 6-hour admin token, there is no
  "regenerate it right before walking on stage" step any more.
- **The storefront ALB's security group is the only access control on `/api/admin/*`.** There
  is no application-level auth on `/api/admin/reset` or `/api/admin/revoke` -- both are buttons
  in the UI, both are reachable by anyone who can reach the ALB. Narrow
  `var.alb_inbound_cidrs` to the presenter's current IP (`curl -s ifconfig.me`) right before
  the talk, and verify from the actual venue network during setup -- conference Wi-Fi can be
  CGNAT'd or simply different from the IP you tested with earlier. Keep widening the allowlist
  as the documented fallback rather than something to improvise on stage.

## Cost and cleanup

Rough eu-west-1 on-demand math, at 1 Vault replica:

| Item | $/hr |
|---|---|
| EKS control plane | 0.10 |
| 2 × t3.medium nodes | 0.09 |
| NAT gateway (single) | 0.048 |
| RDS `db.t4g.micro` + 20 GB gp3 | 0.022 |
| ALB | 0.025 |
| 2 × 10 GiB gp3 (Vault data + audit PVCs) | 0.002 |
| KMS CMK + Secrets Manager × 2 | 0.003 |
| **Total** | **≈ $0.29/hr ≈ $7/day** |

The HCP Essentials Small line item (**$1.578/hr**, the majority of the old ~$1.80/hr total) is
gone entirely -- this is roughly **6× cheaper** than the HCP-based version, independent of
replacing a paid SaaS tier with a demo-appropriate self-managed footprint. Recompute if you
raise `eks_node_count`/`eks_node_instance_type` or `vault_replicas`.

**Run `scripts/destroy.sh` after every rehearsal.** Two new leak modes this migration
introduced, both handled by the script, both worth knowing about if you ever "simplify" it:

1. **Orphaned ALB + target groups.** The AWS Load Balancer Controller is the only thing that
   deletes them; if the storefront `Ingress` outlives the controller (which `terraform destroy`
   removes), the ALB leaks and keeps billing. `destroy.sh` deletes the Ingress and waits for
   the ALB to disappear *before* running `terraform destroy`.
2. **Surviving Vault PVCs.** Helm does not delete `StatefulSet` `volumeClaimTemplate` PVCs on
   uninstall, and deleting the EKS cluster does not delete the EBS volumes behind them.
   `destroy.sh` deletes them explicitly.

The KMS unseal key enters a 7-day pending-deletion window after destroy and bills ~$1/mo until
it elapses -- that's expected, not a leak.

## Verification checklist

1. `scripts/03-verify.sh` passes (self-managed Enterprise up/unsealed/licensed, `auth/spiffe`
   tuned, database engine round-trips, `sys/leases/revoke` works under `agent-support`, the
   audit device is enabled and actually recording, the agent's end-to-end login succeeds, the
   public ALB responds).
2. `scripts/04-verify-agentic-iam.sh` passes and the 4a/4b/4c HTTP codes above are filled in.
3. `vault read database/creds/refund-writer` by hand returns a credential; it can `SELECT`
   `orders` and `INSERT` into `refunds`, and is refused on `customers`; `vault lease revoke`
   kills it and removes the role from `pg_roles`.
4. `kubectl exec` into `agent-secure` shows no secret material beyond the SVID file, and the
   decoded SVID's `sub` matches the SPIRE `ClusterSPIFFEID`'s template.
5. **Negative test**: run the agent from a different service account (or delete the
   `ClusterSPIFFEID`) and confirm `auth/spiffe/login` is refused -- proves identity is
   enforced, not decorative.
6. On the ALB URL: refund an order through the chatbot as an approved action, and confirm the
   storefront's **Audit correlation** tile shows the approver, SPIFFE ID, and lease ID
   together -- and that it persists after a subsequent revoke (the credential is ephemeral,
   the record of who authorized it is not).
7. Confirm the ALB security-group allowlist works in both directions: the site loads from the
   presenter's IP and is refused from anywhere else.
8. `kubectl -n vault delete pod vault-0`: it comes back, auto-unseals via KMS with no human
   input, and the agent's next request succeeds (its cached client re-authenticates).
9. `scripts/demo-beat{1,2,3}.sh` run clean back to back, twice in a row, with
   `scripts/reset.sh` between runs.
10. `scripts/record-demo.sh` produces the fallback video, with the browser window as the
    primary frame, not the terminal.
11. `scripts/destroy.sh` leaves nothing billable -- explicitly including no orphaned ALB,
    target groups, or EBS volumes.
