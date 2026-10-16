# Talk notes: "No Standing Access for AI Agents with Vault Runtime Security and SPIFFE"

Target: ~15 minutes of live demo, four beats, presenter-driven on a live public URL -- the
audience watches the website and chatbot on screen; they do not open the URL themselves. Run
`scripts/reset.sh` immediately before going on stage, confirm the ALB is healthy well before
walking on (2-4 minutes of warm-up after any redeploy, not something to check on the way to
the podium), and have `scripts/record-demo.sh`'s output ready as a fallback video with the
browser window as the primary frame.

## Learning outcomes -> where each one lives in the demo

The abstract promises attendees four things. Each has a specific, literal mechanism below --
not just a slide claim:

| Promised | Demonstrated by |
|---|---|
| **A practical architecture for registering agents** | SPIRE's `ClusterSPIFFEID` (`k8s_manifests/spire/values.yaml`) assigns a SPIFFE identity to the `agent-secure` pod by namespace + service account -- the identity exists before the agent ever calls Vault, not minted on the fly. Beat 4 adds Vault's own literal **Agent Registry**: `vault read agent-registry/registration/display-name/...` shows the agent as a first-class, inventoried identity with a ceiling policy, not just a token. |
| **Enforcing policy at every tool or API call** | Beat 2's scope tile: `orders:SELECT`, `refunds:INSERT` allowed, `customers` denied -- enforced by PostgreSQL grants on a Vault-issued role, re-checked on every query, not cached as a one-time login decision. |
| **Connecting human intent to agent action** | Beat 3: the refund tool call interrupts for approval; the resulting Vault child token carries the approver's name as token metadata, so the *action* and the *approval* are the same auditable event, not two separate logs to correlate by hand. |
| **Building audit-ready controls across Kubernetes, cloud-native, and hybrid environments** | Kubernetes = EKS running SPIRE, both agents, **and Vault itself** (Raft + KMS auto-unseal); cloud-native = Vault's dynamic credentials and AWS KMS; hybrid = the storefront's RDS connection crossing both. The **Audit correlation tile** in the Identity & Access panel is the "audit-ready" proof point: after an approved refund it shows the approver's name, the workload's SPIFFE ID, and the Vault lease id **on one card** -- and it stays there after the credential is revoked, because the credential is ephemeral and the record of who authorized it is not. Vault's own audit log carries the identical three fields on the same request and is verified by `scripts/03-verify.sh`; it is deliberately **not** shown on stage. |

Keep this table in view when cutting slides -- each promise should land on-screen as something
that actually happened in the browser a moment earlier, not as a bullet point asserted on its
own.

## Beat 1 -- standing access is the problem (~3 min)

The support widget is talking to `agent-insecure`: a static password, no identity, created
once and never rotated.

1. Show the secret in the clear (presenter terminal, second window --
   three seconds, genuinely impossible to show in the website itself):
   `kubectl get secret db-static-creds -n nimbus -o jsonpath='{.data.password}' | base64 -d`
   (locally: it's just the `LegacyStaticPassword123!` in `app/db/03_legacy_role.sql`).
2. Ask it to refund **your own** order (#1042) -- it works.
3. Ask it to refund **someone else's** order (#1046, Bob's, while "shopping as" Alice) -- it
   also works. Say the line: *"the credential belongs to the app, not the task -- it has no
   idea whose order this is."*

Run with `scripts/demo-beat1.sh` as a rehearsal harness; on stage, perform this by clicking in
the browser.

## Beat 2 -- SPIFFE identity + just-in-time credential (~5 min)

Switch the widget to `agent-secure`.

1. `kubectl exec deploy/agent-secure -c agent -n agents -- env | grep -iE 'pass|secret'` --
   nothing. No standing credential exists to find. (Presenter terminal -- "there is no secret
   in this pod" cannot be shown by a UI that only renders what the agent reports.)
2. *(Optional -- consider cutting.)* `cat /svids/jwt_svid.token`, decode the payload: `sub` is
   the full SPIFFE ID, `aud: vault`, `exp` five minutes out. The identity tile already shows
   `spiffe_id` plus a live SVID expiry countdown, which is most of what the decoded payload
   shows, in the medium the audience is already watching -- cutting this step saves a window
   switch at the exact moment the panel is most interesting.
3. Ask it to refund order #1045. The panel's lease tile appears, TTL ticking down from 180s,
   scope `orders:SELECT`, `refunds:INSERT`, `customers: ✗ denied`.
4. Ask for a different order's customer, or for another customer's PII directly -- denied,
   and say why: *this isn't an if-statement, PostgreSQL itself has no grant for this role on
   `customers`.*
5. **The money shot**: click **Revoke now** in the panel. Say *"this happens automatically in
   three minutes -- forcing it now so the point lands before we move on."* Same query, now
   fails. `pg_roles` has zero `v-%` rows.

Run with `scripts/demo-beat2.sh` as a rehearsal harness; on stage, perform this by clicking in
the browser.

**Stagecraft:** close any open `psql` session before revoking -- dropping a role does not
kill an already-open connection, and a sharp question from the audience will find that gap if
you don't.

## Beat 3 -- human intent -> agent action -> audit correlation (~4 min)

1. Ask for a refund that's clearly too large (#1044, £450) -- the graph interrupts; the panel
   shows "awaiting approval."
2. Approve it, by name, in the approval card.
3. The agent proceeds under a **child Vault token** carrying the approval as token metadata.
4. The **Audit correlation** tile fills in: approver, SPIFFE ID, lease id, timestamp -- all on
   one card. Say the line: *"the credential is gone in three minutes -- this record is not."*
   (Vault's own audit log carries the identical three fields on this request -- presenter-only
   verification via `scripts/03-verify.sh`, not shown on stage.)

Run with `scripts/demo-beat3.sh "<your name>"` as a rehearsal harness; on stage, perform this
by clicking in the browser.

## Beat 4 -- Agentic IAM (~2 min)

With jwt fallback removed and `auth/spiffe` as the only identity path, **every beat in this
demo now needs the Enterprise license**, not just this one -- a real loss of optionality
compared to the earlier Community/HCP-flexible build, and worth saying so if asked. This beat
shows the HashiCorp product this repo is named after.

1. `vault read agent-registry/registration/display-name/ai-support-agent-secure` -- the agent
   is a first-class, inventoried identity in Vault, not just a token.
2. Present a JWT carrying an `authorization_details` claim constraining it to one path and one
   capability. Then present the identical request with the wrong path, or the wrong
   capability. Say the line: *"this is enforced on top of ACL policy, not instead of it --
   both have to agree."* (See `docs/RUNBOOK.md`'s recorded 4a/4b/4c HTTP codes for exactly what
   happens.)
3. One sentence on what's deliberately NOT shown: real on-behalf-of human delegation needs an
   enterprise IdP doing RFC 8693 token exchange -- *"the ceiling policy and RAR constraint you
   just saw are the mechanics; OBO is the next piece, and it needs an IdP most of you don't
   have yet."*

Run with `scripts/04-verify-agentic-iam.sh` to confirm this beat is live before promising it.

## Prior art worth citing on stage

- **Vault Agentic IAM** (Vault Enterprise 2.1, GA 2026-09-01) -- an Agent Registry, Vault as
  an OAuth resource server, RFC 9396 rich authorization requests, RFC 8693 on-behalf-of
  delegation. This demo's repo name echoes it deliberately.
- HashiCorp's own LangChain + Vault proof of concept (blog, 2025-07-17): Kubernetes
  service-account JWTs, 5-minute credentials, correlated audit trails. This demo's
  differentiator is the SPIFFE layer -- nothing HashiCorp has published ties SPIFFE workload
  identity into this story specifically.
- The validated pattern at
  `developer.hashicorp.com/validated-patterns/vault/ai-agent-identity-with-hashicorp-vault`
  uses an `X-Correlation-Id` header threaded through every layer so it shows up in the audit
  log -- the same idea this demo implements via Vault token `meta`, surfaced live in the
  storefront's own panel.
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
- Real on-behalf-of delegation is not in this demo: it needs an enterprise IdP doing real RFC
  8693 token exchange, which among HashiCorp's documented providers only IBM Verify does.
- **In-cluster Vault traffic is unencrypted** (`global.tlsDisable = true`) -- the SVID and the
  Vault token cross pod boundaries in cleartext, inside the VPC. Correct for a demo torn down
  daily, indefensible in production -- a likely question, answer it directly rather than
  hoping nobody asks.
- **The storefront's admin endpoints have no application-level auth** -- access control is an
  ALB security-group IP allowlist, narrowed to the presenter's IP right before the talk. This
  is why the demo is presenter-driven rather than audience-browsed.
