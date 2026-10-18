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
  storefront's Agentic Workflow panel's Approval stage).
- **A human-approved action's child token (`auth/token/create`) does not inherit the parent's
  identity.** Without deliberately copying `spiffe_id` into the child's `meta` and setting its
  `display_name` (see `vault.py`'s `VaultSession.get_db_credentials`), the audit entry for an
  approved refund shows only the approval fields and a generic "token-token" -- losing the
  "which workload" half of beat 3's claim, and leaving the Agentic Workflow panel's Approval
  stage with nothing to correlate.
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

## Confirmed gotchas from the first real provisioning run (2026-10-17)

`scripts/01-provision.sh` had never been run end-to-end against real AWS before 2026-10-17.
Running it surfaced real bugs, all fixed in this repo -- listed here so they don't get
silently reintroduced:

- **EKS addon ordering deadlock.** This EKS module sets `bootstrap_self_managed_addons =
  false`, so nodes get NO default networking until the `vpc-cni`/`kube-proxy` addons install --
  but the module's default addon ordering waits for the node group to succeed FIRST. Nodes can
  never go `Ready` without CNI, so the node group times out waiting for nodes that can never
  come up. Fix: `terraform/eks.tf` marks `vpc-cni`/`kube-proxy` `before_compute = true`.
- **`gp2` isn't actually the cluster-default StorageClass.** EKS ships it, but without the
  `storageclass.kubernetes.io/is-default-class` annotation -- any PVC that doesn't name a
  `storageClassName` explicitly (Vault's own PVCs, SPIRE's) sits `Pending` forever. Fixed via a
  `kubernetes_annotations` resource in `terraform/eks.tf`, not a manual `kubectl patch`.
- **The `spiffe/spire` Helm chart has moved on from what this repo was originally written
  against.** It now requires `global.spire.caSubject` (country/organization/commonName, no
  default), the field is `jwtTTL` not `jwtTtl` (capitalization changed), and
  `global.spire.recommendations.enabled = true` silently defaults `namespaceLayout` to `true`,
  splitting server/agent across `spire-server`/`spire-system` namespaces instead of the single
  `spire-mgmt` every script here assumes -- set `namespaceLayout: false` explicitly. See
  `k8s_manifests/spire/values.yaml`.
- **The `terraform-provider-vault` plugin crashes creating a second `vault_identity_entity`.**
  A real, reproducible panic (`resource_identity_entity.go`) on the SECOND entity created in one
  apply, not the first -- the entity is actually created in Vault despite the crash, just never
  recorded in Terraform state. Recovery: `terraform import vault_identity_entity.<name> <entity
  id from 'vault read identity/entity/name/<name>'>`, then re-apply.
- **Docker images built on Apple Silicon need `--platform linux/amd64`** for these EKS nodes
  (`t3.medium`, x86_64) -- a plain `docker build` produces an arm64 image that fails every pod
  with `exec format error`. Also set `imagePullPolicy: Always` on every app Deployment: without
  it, a node that already pulled a bad image under the same tag (a git-sha tag can repeat across
  torn-down/rebuilt rehearsals) silently keeps serving it.
- **`k8s_manifests/agent-secure/deployment.yaml`'s `VAULT_ROLE` was wrong** --
  `ai-support-agent` instead of `ai-support-agent-secure` (missing the `-secure` suffix the
  actually-registered SPIFFE role uses). Every refund silently failed at `auth/spiffe/login`
  with no obvious connection to the typo in the error. Fixed; if refunds start failing with
  "permission denied, on post .../auth/spiffe/login" again, check this env var first.
- **`scripts/refresh-bundle.sh`'s JWKS bundle broke every real `auth/spiffe` login.** SPIRE's
  `spire-server bundle show -format spiffe` returns BOTH the x509-svid CA key (no `kid` -- it's
  for mTLS trust, not JWT signing) and the jwt-svid signing key. Vault's `auth/spiffe` `bundle`
  config is JWT-only and its parser rejects the WHOLE bundle if any entry lacks a `kid`
  ("keyID cannot be empty") -- every login failed, silently, because the only check that existed
  (`03-verify.sh`'s "agent-secure reports a real SPIFFE identity") only read a locally-cached
  SVID file, never actually exercised `auth/spiffe/login`. Fixed: `refresh-bundle.sh` now
  filters to `"use": "jwt-svid"` keys only. If you ever see this error again, check this first,
  not Vault's own config.
- **Terraform's `-target` doesn't write pure-variable outputs.** An output that references only
  `var.X` (no resource) never gets written to state during a targeted apply -- it's silently
  absent until a full, untargeted apply succeeds, even though nothing about it actually depends
  on anything untargeted. `terraform/outputs.tf`'s `vault_k8s_namespace` now references
  `kubernetes_namespace.vault.metadata[0].name` instead of the bare variable, specifically so
  Phase 2's targeted apply (which creates that resource) reliably populates it -- `scripts/
  vault-init.sh` and `vault_env()` both need this output before Phase 5's full apply ever runs.
- **`vault write key=value` can't express a list-of-objects field.** `04-verify-agentic-iam.sh`'s
  RAR probe profile (`public_keys`, a list of `{key_id, pem}` objects) needs the real JSON body
  piped to `vault write <path> -` over stdin -- the flat `key=value` CLI syntax only builds
  lists from comma-separated primitives.
- **Two `vault_oauth_resource_server_config_profile` resources can't share an `issuer_id`.**
  The RAR probe profile originally reused `"spiffe://nimbus.demo"`, the same issuer as the real
  `spire` profile -- Vault rejects the second registration outright. `mint_rar_jwt.py`'s probe
  JWT now carries its own `iss` claim (`spiffe://nimbus.demo/rar-probe`) matching a
  correspondingly distinct `issuer_id`.
- **`identity_event()`'s one-shot flag never reset.** It was meant to announce the Agentic Workflow
  panel's Identity card once per chat TURN (so a multi-tool-call turn doesn't spam the log
  twice), but the flag never reset between turns -- after a pod's first-ever conversation, no
  later browser session would ever see that agent's Identity card light up again. Fixed:
  `VaultSession.begin_turn()` / `StaticCredentialSession.begin_turn()`, called at the start of
  every `handle_message()`/`handle_resume()`.
- **`04-verify-agentic-iam.sh`'s misconfiguration test writes a hardcoded policy document
  directly to Vault by name, independent of Terraform.** If `terraform/vault-config.tf`'s
  `order_agent_policy` is ever edited without also updating this script's widen/revert heredocs,
  running the script will silently overwrite the live policy back to a stale version --
  Terraform state has no way to detect this drift, since the write bypasses the `vault_policy`
  resource entirely. Confirmed the hard way: adding the Agent Registry read grant below, then
  running this script, reverted it live under Terraform's nose. Keep the two in sync by hand.
- **`nimbus_app_legacy`'s real Postgres password can silently drift from the
  `db-static-creds` Kubernetes Secret.** Found during a full rehearsal (2026-10-17): the
  Secret's `password` field was empty (likely lost in an earlier `kubectl apply` of
  `k8s_manifests/agent-insecure/secret.yaml` run without `LEGACY_DB_PASSWORD` exported, which
  `envsubst`s it to blank) -- fixed by re-applying that manifest with the documented value.
  But the role's REAL password had also drifted from `app/db/03_legacy_role.sql`'s literal
  (`LegacyStaticPassword123!`), confirmed with a throwaway `kubectl run ... psql` pod before
  touching anything. Unlike the Vault-managed roles, nothing re-asserts this role's password on
  its own -- there's no Terraform resource and no Vault rotation for it. Fixed via the same
  RDS master-password temp-rotation pattern used for app/db writes elsewhere in this doc:
  `aws rds modify-db-instance --master-user-password <temp>` -> `ALTER ROLE nimbus_app_legacy
  WITH PASSWORD '...'` via a throwaway pod -> immediately `vault write -f
  database/rotate-root/nimbus-rds` to hand control back. If beat 1 ever fails with "password
  authentication failed" (not "no password supplied" -- that's the Secret-field-empty case),
  check this first.

## Agent Registry on the storefront UI (2026-10-17)

Each secure agent's real Vault policy now also grants read-only access to its OWN Agent
Registry entry (`agent-registry/registration/display-name/{its own name}` -- see
`terraform/vault-config.tf`), read opportunistically off its already-authenticated client
(never forcing a fresh login just for this) and surfaced via its `/status` endpoint. The
Agentic Workflow panel's Identity cards show the real ceiling policy name as a tag (filtered to
drop Vault's own automatic `default`/`default-ceiling`). This makes beat 4's `vault read
agent-registry/registration/...` terminal step visible live in the browser instead -- keep the
terminal command as a presenter-only cross-check, not the primary demonstration.

## Agentic IAM (Agent Registry + RAR) -- now real, not hypothetical

HashiCorp's **Agentic IAM** (Agent Registry, Vault as an OAuth resource server, RFC 9396 Rich
Authorization Requests) is GA in Vault Enterprise 2.1 (2026-09-01) -- this repo's name echoes
it. `terraform/agentic-iam.tf` registers **two** agents, not one:

- **`refund-agent`** -- the existing `ai-support-agent-secure` identity, unchanged. Can look up
  orders and issue refunds (Vault role `refund-writer`).
- **`order-agent`** -- a genuinely separate SPIFFE identity (`k8s_manifests/order-agent/`,
  own ServiceAccount, own `ClusterSPIFFEID`), Vault-scoped to the read-only `order-reader` DB
  role (`terraform/vault-config.tf`). Cannot issue refunds -- not because of an if-statement,
  but because its PostgreSQL role has no `INSERT` grant on `refunds`. Asking it for a refund
  gets a clean `denied` event (`app/agent/src/agent/actions.py`'s `issue_refund`), the same
  proven mechanism as the `customers`-table denial.

Each has its own ceiling policy (`agent-ceiling` / `order-agent-ceiling`), and both apply
**unconditionally** -- a real trial license is installed on a real, self-managed cluster, so
there's no feature gate left.

**The customer never picks between them.** `app/storefront/main.py`'s `_resolve()` dispatches
"secure" mode to `order-agent` by default (least privilege -- don't hand out refund capability
unless the task needs it) and escalates to `refund-agent` only when the message asks for a
refund. This is a UX convenience, not the security boundary: a mis-routed refund request to
`order-agent` still can't succeed, because Vault/PostgreSQL enforce the real boundary
regardless of what the router guessed.

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
4a (right path, right capability):  HTTP 403 ("permission denied")
4b (wrong path):                    HTTP 403 ("permission denied")
4c (wrong capability):              HTTP 403 ("permission denied")
```

**Confirmed on the real cluster (2026-10-17, Vault 2.2.0+ent):** all three behave identically --
a bare Bearer JWT carrying `authorization_details`, presented directly to a KV path outside any
real OAuth/OBO exchange, is refused regardless of whether its claimed path/capability are
correct. RAR enforcement on this path is **not** real without an actual OBO flow; the
`vault_oauth_resource_server_config_profile` resource configures a real profile, but presenting
a token to it directly doesn't activate RAR-style path/capability checking the way the Terraform
resource's naming might suggest. Beat 4 should NOT claim a live "right capability succeeds, wrong
capability fails" contrast via this path -- that would be theater. What IS real and worth
keeping on stage: the Agent Registry registrations themselves (two agents, two ceiling policies,
both readable and both genuinely different in scope), and the ceiling-vs-normal-token result
below.

**AMENDMENT (2026-10-17, later the same day) -- this finding was about an incomplete token,
not about Vault.** `scripts/mint_rar_jwt.py`'s probe JWT carries only `{iss, sub, aud, iat,
exp, authorization_details}` -- no `act` claim, no `jti`. Meanwhile the real, already-applied
`spire` OAuth resource-server profile's own live state shows Vault defaults `actor_claim` to
`act.sub` and `unique_id_claim` to `jti` server-side, whether anyone sets them or not. A request
missing both required claims gets refused before any path/capability comparison ever happens --
which is a structurally different failure than "RAR isn't enforced." See the real OBO spike
below (`terraform/obo.tf`, `scripts/05-verify-obo.sh`): a correctly-shaped token -- with `act.sub`
and `jti` -- against a profile with `actor_claim` set, DOES get RAR-checked, and the ceiling
genuinely binds it. The 4a/4b/4c codes above are still accurate for what they tested (a bare,
non-OBO-shaped Bearer JWT); they just don't mean what the original write-up concluded.

**The second, newer question**, now that two agents with two different ceilings exist: does
the Agent Registry ceiling cap anything on a **normal** `auth/spiffe`-issued token,
independent of RAR/OBO entirely? Before `order-agent` existed, the one ceiling policy was
always identical in scope to the one agent's real policy -- nothing for it to visibly clip.
`scripts/04-verify-agentic-iam.sh`'s step 5 deliberately widens `order-agent-policy` to also
grant `database/creds/refund-writer` (a plausible operator mistake), then asks `order-agent`'s
own token -- not a bare Bearer JWT, a real `vault login`-shaped token -- to read it. **Record
the actual result here once the script has run:**

```
5. order-agent's own token, with its real policy widened to allow refund-writer:
   vault read database/creds/refund-writer -> SUCCEEDED
```

**Confirmed on the real cluster (2026-10-17, Vault 2.2.0+ent):** SUCCEEDED -- the widened real
policy was honored and the Agent Registry ceiling did NOT block it on a normal
`auth/spiffe`-issued token. This matches the docs' own framing (ceiling enforcement presumes an
OBO flow, and a plain token request isn't one) -- not a surprise, but now confirmed by this
repo's own test rather than assumed from HashiCorp's docs. **Practical consequence for the
talk:** the Agent Registry's ceiling policy is not, by itself, a runtime enforcement backstop
against an operator's ACL-policy mistake -- it constrains what an OBO/RAR-delegated request can
do, not what the agent's own ordinary Vault token can do. The real backstop against the
misconfiguration tested here is still PostgreSQL's own grants (Vault's ACL policy is the thing
that actually widened; the DB role `order-reader` was never touched by this test and still has
no write grant). Frame beat 4 around registration + ceiling-as-declared-intent, not
ceiling-as-live-safety-net -- **for a normal, non-OBO token.** See the next section: with a
correctly-shaped OBO token, the ceiling IS a live safety net.

## OBO -- what was actually tested (2026-10-17, real cluster, Vault 2.2.0+ent)

Phase 0a of `~/.claude/plans/eventual-wandering-tower.md`: does Vault's resource-server mode
enforce the three-way intersection (ceiling ∧ human's own policy ∧ RAR) on a correctly-shaped
OBO token -- `act.sub` + `jti` present, `actor_claim` set on the profile -- entirely with a
locally-signed throwaway key, no external IdP involved yet (`terraform/obo.tf`,
`scripts/05-verify-obo.sh`). **Result: PASS, 5/5.**

```
T1 happy path (RAR=refund-writer, request=refund-writer):              HTTP 200
T2 ceiling should catch this (RAR=customer-pii-reader, human allows):  HTTP 403
T3 RAR path mismatch (RAR=refund-writer, request=order-reader):        HTTP 403
T4 no-actor control (same as T1, no act/jti):                          HTTP 403
T5 human policy narrowed (RAR=refund-writer, human policy revoked it): HTTP 403
```

T2's actual response body: `"2 errors occurred:\n\t* CEILING_POLICY_DENIED: actor ceiling
policy denied permission\n\t* permission denied\n\n"` -- Vault's own error code names the
mechanism. The human's policy (`human-approver-policy`, `terraform/obo.tf`) grants
`customer-pii-reader`; the agent's ceiling (`agent-ceiling`, `terraform/agentic-iam.tf`,
unchanged) does not. **This is the ceiling actually binding a delegated request** -- the exact
thing the earlier "ceiling-as-declared-intent, not ceiling-as-live-safety-net" framing says it
doesn't do for an ordinary token. Both are true; they're about different request shapes.

Also resolved empirically (see `terraform/obo.tf`'s comments for detail): `identity/entity-alias`
needs a `mount_accessor`, and an OAuth resource-server profile genuinely has one
(`oauth-resource-server_root_<config_id>`, readable via `vault read
sys/config/oauth-resource-server/<name>` -- not exposed by the Terraform resource itself, so
read it back via a `vault_generic_secret` data source). The `vault_generic_endpoint` resource
cannot be used to create the alias directly -- `identity/entity-alias`'s base path is
POST-only, and Terraform's read-after-write fails with `405 unsupported operation`; the POST
itself succeeds, so the alias ends up live in Vault but untracked by Terraform until imported
under the correct `vault_identity_entity_alias` resource address.

**What this does NOT prove**: whether IBM Verify (or any real IdP) can actually mint a token
shaped this way via RFC 8693 token exchange -- that's a separate, still-open question (Phase
0b), and this result holds regardless of its answer, since Phase 0a's signing key is entirely
local. See the fallback plan in `eventual-wandering-tower.md` if Phase 0b doesn't pan out: the
Vault-side mechanics demonstrated here are identical either way.

**Phase 0b result (2026-10-18): checked against IBM's own published docs, not tested live.**
`docs.verify.ibm.com`'s OAuth 2.0 and token-exchange pages confirm the grant type
(`urn:ietf:params:oauth:grant-type:token-exchange`) and that delegation mode exists
conceptually (actor_token + subject_token, with a `may_act` claim pre-set on the SUBJECT token
naming the allowed actor -- a different mechanism than this repo's local spike assumed, which
just presents both tokens and expects Verify to figure it out). But `authorization_details`
(RFC 9396 RAR) is **never mentioned anywhere** in either page -- not "undocumented how to use
it," absent entirely, across the main OAuth page and the dedicated token-exchange page, and no
worked example of delegation mode exists at all. That's a vendor-documentation-level signal,
not just "untested," so a full app-registration spike wasn't run live -- the cost (console
setup, a human login, client credentials) wasn't worth it against docs that never describe the
feature this needs. **Decision: ship Phase 1 against the Phase 0a local throwaway signer
instead of a real IdP.** The on-stage line: *"this demo signs the OBO token locally because our
tenant's documented token-exchange flow doesn't support RAR; in production your IdP signs this,
and what Vault enforces on receipt is identical to what you just saw."* If a real IdP with RAR
support on this grant becomes available later, only `app/agent/src/agent/obo.py`'s signing step
needs to change -- everything on the Vault side (the profile, the ceiling, the policies) is
already real.

**Phase 1 shipped (2026-10-18): wired into the app, confirmed live on the real cluster.**
Beat 3's old free-text "type a name" approval is gone -- replaced end-to-end with the real OBO
flow above. `scripts/presenter-login.sh` caches a human identity once
(`POST /api/admin/human-token`); the Agentic Workflow's approval card shows an identity chip
("Approve as X -- expires in Nm") instead of a text box, disabled outright if nothing is
cached. Clicking Approve signals the storefront to inject the cached `sub` into
`/api/support/resume`'s `subject_token` field; `app/agent/src/agent/actions.py`'s
`issue_refund` calls `obo.exchange()` to mint a fresh delegation JWT per request (never reused
-- replay protection via `jti`), then `VaultSession.get_db_credentials(obo_token=...)` presents
it to Vault directly (bypassing `hvac`, which always sends `X-Vault-Token` rather than the
`Authorization: Bearer` resource-server mode needs). Two new events,
`delegation_requested`/`delegation_granted`, make the exchange visible in the event stream.
Confirmed live: a real `>£100` refund through the full chat -> approval -> resume chain
produced the complete real event chain (`approval_granted` -> `identity` ->
`delegation_requested` -> `delegation_granted` -> `auth_completed` -> `credential_issued` ->
`refund_issued`), and `scripts/03-verify.sh` + the ceiling-probe cycle both stayed green
afterward. **One empirical side-finding**: the issued DB lease's `ttl_seconds` came back ~50-60s
on the delegated path, not the DB role's declared `default_ttl = 180` -- Vault appears to cap
the lease to the authenticating token's own remaining validity (`obo.exchange()`'s default
`ttl_seconds=60`), tightening the window further on delegated requests specifically. Not
investigated deeper; noted here in case it matters for a future TTL tuning pass.
`app/agent/src/agent/langchain_engine.py`'s `handle_resume` accepts (but ignores)
`subject_token` for interface parity -- OBO was not wired into the LangChain path, since that
engine's `interrupt()`-based resume already carried its own unvalidated-live caveat before this
work started.

**This test is now clickable live, for BOTH agents, not just run from this script.** The
Agentic Workflow's agent select + "⛰ Probe this agent's ceiling" button
(`POST /api/admin/ceiling-test` on the storefront -> `POST /debug/ceiling-probe` on the
targeted agent -> `VaultSession.probe_ceiling(target_role)` in `app/agent/src/agent/vault.py`)
asks the agent's own, already-authenticated client to attempt its one escalation-target role,
with zero new Vault grant added anywhere for the button itself -- it only works because Vault
re-evaluates a named ACL policy's *content* on every request against any token that already
carries that policy name, so a live `vault policy write` widen immediately changes what an
agent's existing token can do, no re-login needed.

- **order-agent -> `refund-writer`**: the same widen heredoc as this script's step 5, split
  out into `bash scripts/demo-beat4-ceiling.sh widen order` so it can be paced against a live
  click instead of running widen->test->revert in one shot; `revert order` restores the narrow
  policy.
- **refund-agent -> `customer-pii-reader`**: refund-agent already legitimately holds
  `refund-writer` (there's no DB role above it to escalate into), so its plausible-mistake
  target is PII exposure instead. `customer-pii-reader` is a new
  `vault_database_secret_backend_role` (`terraform/vault-config.tf`) scoped to `SELECT` on
  `customers` only -- the table every other role in this repo is deliberately denied (see
  `app/db/01_schema.sql`'s own comment). Never in `agent-support`'s real policy outside the
  deliberate test window. `bash scripts/demo-beat4-ceiling.sh widen refund` /
  `revert refund` drive it the same way.

Cold, either probe is denied (logged as a `ceiling_probe` event, `allowed: false`); after the
matching `widen`, clicking again succeeds live and self-revokes the credential it just proved
it could mint (`allowed: true`); after `revert`, a third click confirms it's denied again. The
privileged widen/revert steps themselves deliberately stay in that script/the presenter's
terminal, not in the app -- giving the storefront a standing Vault credential to run them
itself would be the exact anti-pattern this whole demo argues against.

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
  is no application-level auth on `/api/admin/reset`, `/api/admin/revoke`, or
  `/api/admin/ceiling-test` -- all three are buttons in the UI, all three are reachable by
  anyone who can reach the ALB (the ceiling-test one is harmless by construction -- it adds no
  grant and self-revokes anything it mints -- but still worth naming here). Narrow
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

**Run `scripts/destroy.sh` after every rehearsal.** Confirmed on the first real teardown
(2026-10-18, after the first real provisioning run on 2026-10-17): EKS, the node group, RDS,
the VPC, NAT gateway, security groups, and the EKS encryption KMS key all destroyed cleanly in
one pass once the script was fixed -- but getting there surfaced four real leak modes, all now
handled by the script:

1. **Orphaned ALB + target groups.** The AWS Load Balancer Controller is the only thing that
   deletes them; if the storefront `Ingress` outlives the controller (which `terraform destroy`
   removes), the ALB leaks and keeps billing. `destroy.sh` deletes the Ingress and waits for
   the ALB to disappear *before* running `terraform destroy`.
2. **Surviving Vault AND SPIRE PVCs.** Helm does not delete `StatefulSet`
   `volumeClaimTemplate` PVCs on uninstall, and deleting the EKS cluster does not delete the
   EBS volumes behind them. The script only deleted Vault's PVCs for a long time -- confirmed
   the hard way that SPIRE's own PVC (`spire-data-spire-server-0`) leaks the exact same way;
   `destroy.sh` now deletes both namespaces' PVCs.
3. **`terraform destroy` failing outright with "failed to configure Vault address."** Needs
   `vault_env` called first, same as every other script that touches Vault -- this script
   never called it, because this code path had genuinely never been exercised before (the
   cluster had never been torn down).
4. **`vault_auth_backend.spiffe` / `vault_generic_endpoint.spiffe_config` cannot be destroyed
   through Vault's API at all** -- `DELETE auth/spiffe/config` returns HTTP 405 "unsupported
   operation." Not a transient error; there is no supported way to unconfigure this via the
   API. `destroy.sh` now removes both from Terraform state *before* running `destroy`, so it
   never attempts the impossible call and the whole run completes in one pass instead of
   erroring after ~15 minutes of otherwise-successful AWS teardown.
5. **PVC deletion doesn't mean the EBS volume is gone yet.** The CSI driver needs time to
   actually process a PVC deletion into an EBS volume deletion; if the EKS cluster (and the CSI
   driver running on it) is destroyed first, the volume survives as an orphan regardless of
   step 2 above. The first real run leaked 3 volumes this way (both Vault's and SPIRE's,
   despite their PVCs having been deleted first) because the old version of this script's final
   check only *printed* a table of orphaned volumes rather than deleting them. `destroy.sh` now
   actively deletes anything it finds in `available` state with a `kubernetes.io/created-for/
   pvc/name` tag, rather than just reporting it.

The KMS unseal key enters a 7-day pending-deletion window after destroy and bills ~$1/mo until
it elapses -- that's expected, not a leak. Note also that AWS's Resource Groups Tagging API
(`aws resourcegroupstaggingapi get-resources`) lags real deletion by some minutes -- confirmed
the hard way that instances/ENIs/volumes/a NAT gateway it still listed as tagged were already
independently verified `terminated`/`deleted`/`404` via their own direct `describe-*` calls.
Don't trust the tagging API alone to decide whether something is a real leak; check the
resource's own describe call.

## Verification checklist

1. `scripts/03-verify.sh` passes (self-managed Enterprise up/unsealed/licensed, `auth/spiffe`
   tuned, database engine round-trips, `sys/leases/revoke` works under `agent-support`, the
   audit device is enabled and actually recording, the agent's end-to-end login succeeds, the
   public ALB responds).
2. `scripts/04-verify-agentic-iam.sh` passes, the 4a/4b/4c HTTP codes above are filled in, and
   the misconfiguration ceiling test's result is recorded.
3. `vault read database/creds/refund-writer` by hand returns a credential; it can `SELECT`
   `orders` and `INSERT` into `refunds`, and is refused on `customers`; `vault lease revoke`
   kills it and removes the role from `pg_roles`. `vault read database/creds/order-reader` by
   hand returns a credential that can `SELECT` `orders`/`products` and is refused on
   `refunds`/`customers`.
4. `kubectl exec` into `agent-secure` **and** `order-agent` both show no secret material beyond
   the SVID file, and each decoded SVID's `sub` matches its own `ClusterSPIFFEID` template --
   `.../sa/ai-support-agent-secure` and `.../sa/ai-order-agent` respectively.
5. **Negative test**: run the agent from a different service account (or delete a
   `ClusterSPIFFEID`) and confirm `auth/spiffe/login` is refused -- proves identity is
   enforced, not decorative. **Second negative test**: ask `order-agent` directly for a refund
   (`scripts/demo-beat4-agentic-iam.sh`'s last step) and confirm a clean `denied` event, not a
   500 -- proves the InsufficientPrivilege catch in `actions.py`'s `issue_refund` actually
   fires.
6. On the ALB URL: refund an order through the chatbot as an approved action, and confirm the
   Agentic Workflow panel's **Approval** stage shows the approver, SPIFFE ID, and lease ID
   together -- and that it persists after a subsequent revoke of the Credential stage (the
   credential is ephemeral, the record of who authorized it is not).
7. Confirm the ALB security-group allowlist works in both directions: the site loads from the
   presenter's IP and is refused from anywhere else.
8. `kubectl -n vault delete pod vault-0`: it comes back, auto-unseals via KMS with no human
   input, and the agent's next request succeeds (its cached client re-authenticates).
9. `scripts/demo-beat{1,2,3}.sh` and `scripts/demo-beat4-agentic-iam.sh` run clean back to
   back, twice in a row, with `scripts/reset.sh` between runs.
10. `scripts/record-demo.sh` produces the fallback video, with the browser window as the
    primary frame, not the terminal.
11. `scripts/destroy.sh` leaves nothing billable -- explicitly including no orphaned ALB,
    target groups, or EBS volumes.
