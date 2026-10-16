# Talk notes: "No Standing Access for AI Agents with Vault Runtime Security and SPIFFE"

Target: ~13 minutes of live demo, three beats. Run `scripts/reset.sh` immediately before
going on stage, and have `scripts/record-demo.sh`'s output ready as a fallback video.

## Learning outcomes -> where each one lives in the demo

The abstract promises attendees four things. Each has a specific, literal mechanism below --
not just a slide claim:

| Promised | Demonstrated by |
|---|---|
| **A practical architecture for registering agents** | SPIRE's `ClusterSPIFFEID` (`k8s_manifests/spire/values.yaml`) assigns a SPIFFE identity to the `agent-secure` pod by namespace + service account -- the identity exists before the agent ever calls Vault, not minted on the fly. Beat 4 (conditional) adds Vault's own literal **Agent Registry**: `vault read agent-registry/registration/display-name/...` shows the agent as a first-class, inventoried identity with a ceiling policy, not just a token. |
| **Enforcing policy at every tool or API call** | Beat 2's scope tile: `orders:SELECT`, `refunds:INSERT` allowed, `customers` denied -- enforced by PostgreSQL grants on a Vault-issued role, re-checked on every query, not cached as a one-time login decision. |
| **Connecting human intent to agent action** | Beat 3: the refund tool call interrupts for approval; the resulting Vault child token carries the approver's name as token metadata, so the *action* and the *approval* are the same auditable event, not two separate logs to correlate by hand. |
| **Building audit-ready controls across Kubernetes, cloud-native, and hybrid environments** | Kubernetes = EKS running SPIRE + both agents; cloud-native = HCP Vault Dedicated issuing the credentials; hybrid = the storefront's RDS connection crossing both. Beat 3's single audit record (`auth.metadata.spiffe_id` + `auth.metadata.approved_by`) is the "audit-ready" proof point -- one line answers "who, what, approved by whom, when" without stitching logs together. |

Keep this table in view when cutting slides -- each promise should land on-screen as something
that actually happened in the terminal/browser a moment earlier, not as a bullet point asserted
on its own.

## Beat 1 -- standing access is the problem (~3 min)

The support widget is talking to `agent-insecure`: a static password, no identity, created
once and never rotated.

1. Show the secret in the clear:
   `kubectl get secret db-static-creds -n nimbus -o jsonpath='{.data.password}' | base64 -d`
   (locally: it's just the `LegacyStaticPassword123!` in `app/db/03_legacy_role.sql`).
2. Ask it to refund **your own** order (#1042) -- it works.
3. Ask it to refund **someone else's** order (#1046, Bob's, while "shopping as" Alice) -- it
   also works. Say the line: *"the credential belongs to the app, not the task -- it has no
   idea whose order this is."*

Run with `scripts/demo-beat1.sh`.

## Beat 2 -- SPIFFE identity + just-in-time credential (~5 min)

Switch the widget to `agent-secure`.

1. `kubectl exec deploy/agent-secure -c agent -n agents -- env | grep -iE 'pass|secret'` --
   nothing. No standing credential exists to find.
2. `cat /svids/jwt_svid.token`, decode the payload: `sub` is the full SPIFFE ID, `aud: vault`,
   `exp` five minutes out.
3. Ask it to refund order #1045. The panel's lease tile appears, TTL ticking down from 180s,
   scope `orders:SELECT`, `refunds:INSERT`, `customers: ✗ denied`.
4. Ask for a different order's customer, or for another customer's PII directly -- denied,
   and say why: *this isn't an if-statement, PostgreSQL itself has no grant for this role on
   `customers`.*
5. **The money shot**: `vault lease revoke <lease_id>` on command. Say *"this happens
   automatically in three minutes -- forcing it now so the point lands before we move on."*
   Same query, now fails. `pg_roles` has zero `v-%` rows.

Run with `scripts/demo-beat2.sh`.

**Stagecraft:** close any open `psql` session before revoking -- dropping a role does not
kill an already-open connection, and a sharp question from the audience will find that gap if
you don't.

## Beat 3 -- human intent -> agent action -> audit trail (~4 min)

1. Ask for a refund that's clearly too large (#1044, £450) -- the graph interrupts; the panel
   shows "awaiting approval."
2. Approve it, by name.
3. The agent proceeds under a **child Vault token** carrying the approval as token metadata.
4. Pull up the pre-saved CloudWatch Logs Insights query (or, locally,
   `docker exec nimbus-demo-vault-1 sh -c "tail -2 /tmp/vault_audit.log"`). One record:
   `request.path = database/creds/refund-writer`, `auth.metadata.spiffe_id` (the workload),
   `auth.metadata.approved_by` (the human), and a timestamp. Workload identity, human intent,
   resource, and time -- one line.

Run with `scripts/demo-beat3.sh "<your name>"`.

## Beat 4 -- Agentic IAM (bonus, ONLY if `scripts/04-verify-agentic-iam.sh` passed) (~2 min)

Everything above runs on Vault Community/HCP with no Enterprise license. This beat shows the
real HashiCorp product this repo is named after -- **only if you actually got a trial license
and `scripts/dev/configure_agentic_iam.sh` confirmed RAR enforcement works** (see
`docs/RUNBOOK.md`'s "Agentic IAM" section; do not promise this beat and then discover live
that it doesn't work).

1. `vault read agent-registry/registration/display-name/ai-support-agent-secure` -- the agent
   is a first-class, inventoried identity in Vault, not just a token.
2. Present a JWT carrying an `authorization_details` claim constraining it to one path and one
   capability. Then present the identical request with the wrong path, or the wrong
   capability. Say the line: *"this is enforced on top of ACL policy, not instead of it --
   both have to agree."*
3. One sentence on what's deliberately NOT shown: real on-behalf-of human delegation needs
   Vault 2.2 (not GA yet) and an enterprise IdP doing RFC 8693 token exchange -- *"the ceiling
   policy and RAR constraint you just saw are the mechanics; OBO is the next piece HashiCorp
   ships."*

**If the probe failed or you never got a license**: skip this beat entirely. Beats 1-3 are
the complete talk; this is strictly a bonus, not a dependency.

## Prior art worth citing on stage

- **Vault Agentic IAM** (Vault Enterprise 2.1, GA 2026-09-01) -- an Agent Registry, Vault as
  an OAuth resource server, RFC 9396 rich authorization requests, RFC 8693 on-behalf-of
  delegation. This demo's repo name echoes it deliberately. Beats 1-3 run on Vault
  Community/HCP, no license needed; beat 4 (above, conditional) shows the real feature if a
  trial license came through in time.
- HashiCorp's own LangChain + Vault proof of concept (blog, 2025-07-17): Kubernetes
  service-account JWTs, 5-minute credentials, correlated audit trails. This demo's
  differentiator is the SPIFFE layer -- nothing HashiCorp has published ties SPIFFE workload
  identity into this story specifically.
- The validated pattern at
  `developer.hashicorp.com/validated-patterns/vault/ai-agent-identity-with-hashicorp-vault`
  uses an `X-Correlation-Id` header threaded through every layer so it shows up in the audit
  log -- the same idea this demo implements via Vault token `meta`, just without needing an
  external IdP.
- **No `langchain-vault` library exists.** The `@tool` wrapper around `hvac` in
  `app/agent/src/agent/langchain_tools.py` *is* the current state of the art, not a shortcut.

## If asked: what's not real here

- "Task-scoped" means capability- and lifetime-scoped, not row-scoped -- Vault's database
  secrets engine can't take per-request parameters. True row-level scoping would need
  PostgreSQL RLS driven by a session variable. Worth a sentence as "where this goes next";
  don't claim more than the architecture actually does.
- The LangChain engine (`AGENT_ENGINE=langchain`) is written to the documented `create_agent` +
  `interrupt()` API but was not exercised against a live model while building this -- the
  deterministic engine (`AGENT_ENGINE=deterministic`) is what every beat above was actually
  validated against. Run the LangChain path at least once in rehearsal before trusting it live.
- Beat 4's RAR enforcement is written to the documented API shape but, as of writing this,
  had never actually been run against Vault Enterprise at all -- no license was obtainable
  without a sales/support conversation, and Enterprise's dev-mode binary refuses to start
  without one (confirmed by direct test). If asked whether real on-behalf-of delegation is in
  this demo: no -- it needs Vault 2.2 (not GA) and an enterprise IdP doing real RFC 8693
  token exchange, which among HashiCorp's documented providers only IBM Verify does.
