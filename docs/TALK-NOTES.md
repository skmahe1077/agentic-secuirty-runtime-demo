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
| **A practical architecture for registering agents** | SPIRE's `ClusterSPIFFEID`s (`k8s_manifests/spire/values.yaml`) assign a SPIFFE identity to each agent pod by namespace + service account -- the identity exists before the agent ever calls Vault, not minted on the fly. Beat 4 adds Vault's own literal **Agent Registry**: `vault read agent-registry/registration/display-name/order-agent` and `.../refund-agent` show two first-class, inventoried identities, each with its own ceiling policy -- not just tokens, and not just one agent. |
| **Enforcing policy at every tool or API call** | Beat 2's scope tile: `orders:SELECT`, `refunds:INSERT` allowed, `customers` denied -- enforced by PostgreSQL grants on a Vault-issued role, re-checked on every query, not cached as a one-time login decision. |
| **Connecting human intent to agent action** | Beat 3: the refund tool call interrupts for approval; the resulting Vault child token carries the approver's name as token metadata, so the *action* and the *approval* are the same auditable event, not two separate logs to correlate by hand. |
| **Building audit-ready controls across Kubernetes, cloud-native, and hybrid environments** | Kubernetes = EKS running SPIRE, both agents, **and Vault itself** (Raft + KMS auto-unseal); cloud-native = Vault's dynamic credentials and AWS KMS; hybrid = the storefront's RDS connection crossing both. The **Control Room panel's Approval stage** is the "audit-ready" proof point: after an approved refund its detail drawer shows the approver's name, the workload's SPIFFE ID, and the Vault lease id **together** -- and it stays complete after the Credential stage is revoked, because the credential is ephemeral and the record of who authorized it is not. Vault's own audit log carries the identical three fields on the same request and is verified by `scripts/03-verify.sh`; it is deliberately **not** shown on stage. |

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
3. Ask it to refund **someone else's** order (#1046, Ilan's, while "shopping as" Idhazhini) -- it
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
   the full SPIFFE ID, `aud: vault`, `exp` five minutes out. The Control Room panel's
   **Identity** stage, clicked open, already shows `spiffe_id` plus a live SVID expiry
   countdown, which is most of what the decoded payload shows, in the medium the audience is
   already watching -- cutting this step saves a window switch at the exact moment the panel
   is most interesting.
3. Ask it to refund order #1045. The **Identity** and **Authenticate** stages complete first
   (SPIRE, then `auth/spiffe`) -- **Approval** shows its dashed bypass arc instead of lighting
   up, since £64 is under the £100 threshold -- then **Credential**: click it open to show the
   TTL ticking down from 180s, scope `orders:SELECT`, `refunds:INSERT`, `customers: ✗ denied`.
4. Ask for a different order's customer, or for another customer's PII directly -- denied,
   and say why: *this isn't an if-statement, PostgreSQL itself has no grant for this role on
   `customers`.*
5. **The money shot**: click the **Credential** stage in the Control Room panel, then
   **Revoke now** in its detail drawer. Say *"this happens automatically in three minutes --
   forcing it now so the point lands before we move on."* Same query, now fails. `pg_roles`
   has zero `v-%` rows, and the Credential stage's live countdown flips to "revoked."

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
4. Click the **Approval** stage in the Control Room panel: its detail drawer now shows the
   approver, SPIFFE ID, and lease id together. Say the line: *"the credential is gone in three
   minutes -- this record is not."* (Vault's own audit log carries the identical three fields
   on this request -- presenter-only verification via `scripts/03-verify.sh`, not shown on
   stage.)

Run with `scripts/demo-beat3.sh "<your name>"` as a rehearsal harness; on stage, perform this
by clicking in the browser.

## Beat 4 -- two agents, one registry, real restriction (~3 min)

With `auth/spiffe` as the only identity path, **every beat in this demo now needs the
Enterprise license**, not just this one -- a real loss of optionality compared to the earlier
Community/HCP-flexible build, and worth saying so if asked. This beat shows the HashiCorp
product this repo is named after, and it's the one beat where the audience hasn't seen the
mechanism yet: **there are two agents behind "Zero-trust," not one.**

1. Open the Control Room tab -- the Identity column already shows **both** agents, live,
   before a single message is sent: `order-agent` and `refund-agent`, each with its own real
   ceiling-policy tag (`order-agent-ceiling` / `agent-ceiling`) read straight off Vault's Agent
   Registry. Say the line: *"these are two first-class, inventoried identities in Vault, each
   with its own ceiling policy -- not just tokens, and not just one agent."*
   (`vault read agent-registry/registration/display-name/order-agent` in a presenter terminal
   is the cross-check, not the primary proof -- the tag on the card already is.)
2. In the chat, ask a plain status question ("where is order #1043") -- say the line: *"this
   got routed to the read-only agent, automatically -- nobody picked it."* The `order-agent`
   card lights up green; `refund-agent`'s card stays visibly present -- it's real and
   registered -- but dim.
3. In the **same conversation**, ask for a refund. Now `refund-agent`'s card lights up instead
   -- a completely different workload picked up the thread, because the task changed. The
   refund succeeds.
4. **The point**: start a *new* thread, and ask for a refund worded so the router's keyword
   match misses (e.g. "can you sort out order #1042, it arrived damaged" -- no literal
   "refund"). It still gets denied, cleanly. Say the line: *"the router is a convenience, not
   the security boundary -- even when it guesses wrong, PostgreSQL still won't let the
   read-only agent write a refund."* Run with `scripts/demo-beat4-agentic-iam.sh` as a
   rehearsal harness for all of the above.
5. One sentence on what's confirmed and what isn't (presenter-only detail, not worth a live
   click -- **do not claim this live**): a bare Bearer JWT carrying `authorization_details`,
   presented directly outside a real OAuth/OBO exchange, was tested on this real cluster and
   refused identically (HTTP 403) whether its path/capability claim was right or wrong -- RAR
   enforcement on this path isn't real without an actual OBO flow. Separately, the Agent
   Registry's ceiling policy did NOT block a normal `auth/spiffe` token after its real policy
   was deliberately widened -- the ceiling constrains an OBO/RAR-delegated request, not an
   agent's own ordinary token. (See `docs/RUNBOOK.md`'s recorded 4a/4b/4c HTTP codes and the
   misconfiguration-test result.) What IS real and demo-able: the Agent Registry itself (two
   first-class registrations, two genuinely different ceiling policies), and the PostgreSQL-
   level denial in point 4 above.
6. One sentence on what's deliberately NOT shown: real on-behalf-of human delegation needs an
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
