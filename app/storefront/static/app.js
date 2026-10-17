// Mahi Stores frontend. No build step, no framework -- this runs
// unmodified off a static file mount so there's one less thing to break on
// stage.
//
// Event contract (produced by the agent services, relayed verbatim by the
// storefront, consumed here):
//   { type: "identity", spiffe_id, svid_expires_at, ttl_seconds, message }
//   { type: "auth_completed", auth_mount, message }
//   { type: "credential_issued", lease_id, lease_role, expires_at, ttl_seconds,
//     scope: [{resource, action, allowed}],
//     approval: {approval_id, approved_by, spiffe_id} | null, message }
//   { type: "credential_revoked", lease_id, message }
//   { type: "denied", resource, message }
//   { type: "scope_violation", resource, message }
//   { type: "approval_requested", approval_id, amount_pence, message }
//   { type: "approval_granted", approval_id, approved_by, message }
//   { type: "refund_issued", order_id, amount_pence, message }
//   { type: "info" | "error", message }
// Every event also carries `ts` (epoch seconds), added by the storefront if
// the agent didn't set one.

// The Security Flow panel's 6 stages. One source of truth for both the
// compact stage boxes and the detail drawer -- content lives here, not in
// index.html. Each stage's `eventTypes` is what actually completes it; no
// stage is faked complete by a timer or a scripted sequence.
const STAGES = [
  {
    id: "identity", num: 1, label: "Identity", eventTypes: ["identity"],
    what: "SPIRE issues the agent pod a short-lived JWT-SVID over the SPIFFE Workload API, written to disk by the spiffe-helper sidecar.",
    why: "The agent's identity exists before it ever calls Vault -- it isn't minted on the fly or typed in by anyone.",
    tags: ["SPIRE", "JWT-SVID", "5 min TTL"],
  },
  {
    id: "auth", num: 2, label: "Auth", eventTypes: ["auth_completed"],
    what: "The agent presents its SVID as a Bearer token to Vault's native auth/spiffe method, which verifies the signature and issues a short-lived Vault token.",
    why: "No password, no API key -- identity is the credential. A workload with a different identity is refused outright.",
    tags: ["auth/spiffe", "Vault Enterprise"],
  },
  {
    id: "credential", num: 3, label: "Credential", eventTypes: ["credential_issued"],
    what: "Vault's database secrets engine mints a brand-new PostgreSQL role, scoped to exactly orders:SELECT + refunds:INSERT, with a 3-minute TTL.",
    why: "The credential is task-scoped and self-destructing -- not a standing password that outlives the task.",
    tags: ["database secrets engine", "180s TTL", "least privilege"],
  },
  {
    id: "approval", num: 4, label: "Approval", eventTypes: ["approval_requested", "approval_granted"],
    what: "Refunds over the threshold pause the agent and wait for a named human to approve; the approval becomes metadata on a freshly-minted Vault child token.",
    why: "Human intent and agent action are tied to the same auditable event -- not two logs to stitch together by hand.",
    tags: ["human-in-the-loop", "Vault child token"],
  },
  {
    id: "execute", num: 5, label: "Execute", eventTypes: ["refund_issued", "denied", "scope_violation"],
    what: "The scoped credential runs exactly one query -- PostgreSQL itself enforces the boundary, not application logic.",
    why: "Ask for something outside scope (another customer's PII) and the database refuses it -- the same mechanism, not a special case.",
    tags: ["PostgreSQL grants"],
  },
  {
    id: "revoke", num: 6, label: "Revoke", eventTypes: ["credential_revoked"],
    what: "The lease is killed -- on command, or automatically at 3 minutes -- and the PostgreSQL role backing it is dropped.",
    why: "There is nothing left to steal once this happens. No key rotation needed, because there's no standing key.",
    tags: ["vault lease revoke"],
  },
];
const STAGE_BY_TYPE = {};
for (const s of STAGES) for (const t of s.eventTypes) STAGE_BY_TYPE[t] = (STAGE_BY_TYPE[t] || []).concat(s.id);

const state = {
  customerId: 1,
  agent: "secure",
  identity: null,       // last identity event
  lease: null,           // last credential_issued event (cleared on revoke/expiry)
  correlation: null,     // last approved credential's {approved_by, spiffe_id, lease_id, approval_id, ts} -- NOT cleared on revoke, see applyEvents
  stageEvents: Object.fromEntries(STAGES.map((s) => [s.id, []])),
  openStage: null,        // which stage's detail drawer is open, if any
  pendingApproval: null, // {approval_id, thread_id}
  threadId: "demo",
};

const $ = (id) => document.getElementById(id);

async function j(method, url, body) {
  const r = await fetch(url, {
    method,
    headers: body ? { "Content-Type": "application/json" } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!r.ok) throw new Error(`${method} ${url} -> ${r.status}`);
  return r.json();
}

function money(pence) {
  return `£${(pence / 100).toFixed(2)}`;
}

function fmtTime(ts) {
  return new Date(ts * 1000).toLocaleTimeString([], { hour12: false });
}

// ---------- catalog ----------

// Real product photos (Wikimedia Commons, freely licensed -- see
// static/images/ATTRIBUTION.md), bundled locally and served as static
// files -- not hotlinked to an external host. Keyed by a keyword matched
// against the product name, not product_id, so new catalog rows pick up a
// sensible image for free. Local, not a live external URL: nothing to
// fail to load if the venue Wi-Fi drops mid-talk.
const PRODUCT_IMAGES = {
  headphone: "headphones.jpg",
  keyboard: "keyboard.jpg",
  monitor: "monitor.png",
  charger: "charger.jpg",
  mouse: "mouse.jpg",
  stand: "stand.jpg",
  webcam: "webcam.jpg",
  speaker: "speaker.jpg",
  sleeve: "sleeve.jpg",
  hub: "hub.jpg",
};

function _imageFor(name) {
  const lower = name.toLowerCase();
  for (const [keyword, file] of Object.entries(PRODUCT_IMAGES)) {
    if (lower.includes(keyword)) return `/static/images/${file}`;
  }
  return null;
}

async function loadCustomers() {
  const customers = await j("GET", "/api/customers");
  const sel = $("customer-picker");
  sel.innerHTML = "";
  for (const c of customers) {
    const opt = document.createElement("option");
    opt.value = c.customer_id;
    opt.textContent = c.name;
    sel.appendChild(opt);
  }
  sel.value = state.customerId;
}

async function loadProducts() {
  const products = await j("GET", "/api/products");
  const grid = $("products");
  grid.innerHTML = "";
  for (const p of products) {
    const card = document.createElement("div");
    card.className = "product-card";
    const imgSrc = _imageFor(p.name);
    const imageHtml = imgSrc
      ? `<img src="${imgSrc}" alt="${p.name}" loading="lazy" />`
      : "";
    card.innerHTML = `
      <div class="product-image">${imageHtml}</div>
      <div class="product-body">
        <div class="name">${p.name}</div>
        <div class="description">${p.description}</div>
        <div class="price">${money(p.price_pence)}</div>
      </div>`;
    grid.appendChild(card);
  }
}

// ---------- chat ----------

function addChatBubble(text, who, denied) {
  const log = $("chat-log");
  const bubble = document.createElement("div");
  bubble.className = `chat-bubble ${who}${denied ? " denied" : ""}`;
  bubble.textContent = text;
  log.appendChild(bubble);
  log.scrollTop = log.scrollHeight;
  return bubble;
}

// Quick-reply chips, shown above the input. Clicking one sends it through
// the exact same path as typing it -- no separate code path to keep honest.
const SUGGESTIONS = ["Check my order status", "Request a refund"];
function renderSuggestions() {
  const wrap = $("chat-suggestions");
  wrap.innerHTML = "";
  for (const text of SUGGESTIONS) {
    const chip = document.createElement("button");
    chip.type = "button";
    chip.className = "chip";
    chip.textContent = text;
    chip.addEventListener("click", () => {
      $("chat-input").value = text;
      $("chat-form").requestSubmit();
    });
    wrap.appendChild(chip);
  }
}

// ---------- floating widget open/close ----------

let _chatOpened = false;
function openChatWidget() {
  $("chat-launcher").classList.add("hidden");
  $("chat-widget").classList.remove("hidden");
  if (!_chatOpened) {
    _chatOpened = true;
    $("chat-open-time").textContent = fmtTime(Date.now() / 1000);
    addChatBubble("Hi! I'm the Mahi Stores assistant -- ask about an order, or request a refund.", "agent");
  }
  $("chat-input").focus();
}
function closeChatWidget() {
  $("chat-widget").classList.add("hidden");
  $("chat-launcher").classList.remove("hidden");
}
$("chat-launcher").addEventListener("click", openChatWidget);
$("chat-close-btn").addEventListener("click", closeChatWidget);
// No separate minimized state -- collapse just goes back to the launcher,
// same as close.
$("chat-collapse-btn").addEventListener("click", closeChatWidget);
// Decorative only -- there is no audio anywhere in this demo to mute.
$("chat-mute-btn").addEventListener("click", () => {
  const btn = $("chat-mute-btn");
  btn.textContent = btn.textContent.trim() === "🔊" ? "🔇" : "🔊";
});

// A loading-state label guessed from the customer's own message -- not
// fabricated telemetry, just what's about to be asked for. The real
// events (and which backend actually handled it) only arrive with the
// response; this bubble is removed the moment they do.
function _guessCallingLabel(message) {
  if (/refund/i.test(message)) return "Calling issue_refund…";
  if (/order|status|track|where is|find/i.test(message)) return "Calling lookup_order…";
  return "Calling support agent…";
}

$("chat-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const input = $("chat-input");
  const sendBtn = $("chat-form").querySelector("button[type=submit]");
  const message = input.value.trim();
  if (!message) return;
  addChatBubble(message, "user");
  input.value = "";

  const callingBubble = addChatBubble(_guessCallingLabel(message), "calling");
  const placeholder = input.placeholder;
  input.disabled = true;
  sendBtn.disabled = true;
  input.placeholder = "Waiting…";
  try {
    const resp = await j("POST", "/api/support/chat", {
      customer_id: state.customerId,
      agent: state.agent,
      message,
      thread_id: state.threadId,
    });
    callingBubble.remove();
    handleAgentResponse(resp);
  } catch (err) {
    callingBubble.remove();
    addChatBubble(`(error contacting agent: ${err})`, "agent", true);
  } finally {
    input.disabled = false;
    sendBtn.disabled = false;
    input.placeholder = placeholder;
    input.focus();
  }
});

function handleAgentResponse(resp) {
  const denied = (resp.events || []).some((e) => e.type === "denied");
  addChatBubble(resp.reply, "agent", denied);
  applyEvents(resp.events || []);
  if (resp.requires_approval) {
    state.pendingApproval = { approval_id: resp.approval_id, thread_id: state.threadId };
    showApprovalCard(resp.approval_text || "This action needs human approval.");
  }
}

function showApprovalCard(text) {
  const card = $("approval-card");
  card.classList.remove("hidden");
  card.querySelector(".approval-text").textContent = text;
}
function hideApprovalCard() {
  $("approval-card").classList.add("hidden");
}

$("approve-btn").addEventListener("click", async () => {
  const approver = $("approver-name").value.trim() || "anonymous";
  if (!state.pendingApproval) return;
  try {
    const resp = await j("POST", "/api/support/resume", {
      agent: state.agent,
      thread_id: state.pendingApproval.thread_id,
      approved_by: approver,
    });
    hideApprovalCard();
    state.pendingApproval = null;
    handleAgentResponse(resp);
  } catch (err) {
    addChatBubble(`(error resuming: ${err})`, "agent", true);
  }
});

$("revoke-btn").addEventListener("click", async () => {
  try {
    const resp = await j("POST", "/api/admin/revoke", { agent: state.agent, thread_id: state.threadId });
    applyEvents(resp.events || []);
  } catch (err) {
    addChatBubble(`(revoke failed: ${err})`, "agent", true);
  }
});

function resetFlowState() {
  state.lease = null;
  state.identity = null;
  state.correlation = null;
  state.openStage = null;
  for (const s of STAGES) state.stageEvents[s.id] = [];
  $("stage-detail").classList.add("hidden");
}

$("reset-btn").addEventListener("click", async () => {
  await j("POST", "/api/admin/reset");
  resetFlowState();
  $("chat-log").innerHTML = "";
  $("event-log").innerHTML = "";
  renderFlow();
  renderSuggestions();
});

$("customer-picker").addEventListener("change", (e) => {
  state.customerId = parseInt(e.target.value, 10);
});
$("agent-picker").addEventListener("change", (e) => {
  state.agent = e.target.value;
  resetFlowState();
  renderFlow();
});

// ---------- tabs ----------
// "Shop" is the consumer-facing view; "Security Flow" holds the demo-only
// controls (customer/agent pickers) plus the flow panel -- a real shopper
// never sees those, so they don't live in the default view.

function switchTab(name) {
  for (const btn of document.querySelectorAll(".tab-btn")) {
    btn.classList.toggle("active", btn.dataset.tab === name);
  }
  $("tab-shop").classList.toggle("hidden", name !== "shop");
  $("tab-flow").classList.toggle("hidden", name !== "flow");
}
$("tab-btn-shop").addEventListener("click", () => switchTab("shop"));
$("tab-btn-flow").addEventListener("click", () => switchTab("flow"));

// ---------- Security Flow panel ----------

function applyEvents(events) {
  for (const e of events) {
    logEvent(e);
    const stageIds = STAGE_BY_TYPE[e.type] || [];
    for (const id of stageIds) state.stageEvents[id].push(e);

    if (e.type === "identity") state.identity = e;
    if (e.type === "credential_issued") {
      state.lease = e;
      if (e.approval) {
        // Deliberately NOT cleared on revoke or expiry below: the
        // credential is ephemeral, the record of who authorised it is
        // not. That asymmetry is what the Approval stage's detail shows.
        state.correlation = { ...e.approval, lease_id: e.lease_id, ts: e.ts || Date.now() / 1000 };
      }
    }
    if (e.type === "credential_revoked" && state.lease && state.lease.lease_id === e.lease_id) {
      state.lease = { ...state.lease, revoked: true };
    }
  }
  renderFlow();
}

function logEvent(e) {
  const log = $("event-log");
  const li = document.createElement("li");
  const dot = document.createElement("span");
  dot.className = `status-dot ${dotClassFor(e)}`;
  const time = document.createElement("time");
  time.textContent = fmtTime(e.ts || Date.now() / 1000);
  const text = document.createElement("span");
  text.textContent = e.message || e.type;
  li.append(dot, time, text);
  log.prepend(li);
  while (log.children.length > 40) log.removeChild(log.lastChild);
}

function dotClassFor(e) {
  if (e.type === "denied" || e.type === "error" || e.type === "credential_revoked") return "critical";
  if (e.type === "approval_requested") return "warning";
  if (e.type === "credential_issued" || e.type === "refund_issued" || e.type === "approval_granted") return "good";
  return "neutral";
}

function shortLease(leaseId) {
  if (!leaseId) return "";
  const parts = leaseId.split("/");
  return parts[parts.length - 1].slice(0, 10) + "…";
}

function remainingLabel(expiresAt) {
  if (!expiresAt) return "";
  const remaining = Math.max(0, expiresAt - Date.now() / 1000);
  const m = Math.floor(remaining / 60);
  const s = Math.floor(remaining % 60);
  return `expires in ${m}:${String(s).padStart(2, "0")}`;
}

function buildFlowDOM() {
  const flow = $("flow");
  flow.innerHTML = "";
  for (const s of STAGES) {
    const box = document.createElement("div");
    box.className = "flow-stage";
    box.id = `flow-${s.id}`;
    box.innerHTML = `
      <div class="flow-stage-head">
        <span class="flow-num">${s.num}</span>
        <span class="flow-label">${s.label}</span>
      </div>
      <div class="flow-sub" id="flow-sub-${s.id}">—</div>`;
    box.addEventListener("click", () => openStageDetail(s.id));
    flow.appendChild(box);
  }
}

function openStageDetail(id) {
  state.openStage = id;
  $("stage-detail").classList.remove("hidden");
  renderFlow();
}
$("stage-detail-close").addEventListener("click", () => {
  state.openStage = null;
  $("stage-detail").classList.add("hidden");
  renderFlow();
});

// Exactly one stage, Auth, genuinely never fires for agent-insecure --
// StaticCredentialSession.auth_event() always returns null, there is no
// auth/spiffe login to report. Every other stage renders from whatever
// real events actually happened (lookup_order/issue_refund's approval
// gate, for instance, runs for BOTH agents -- it is not Vault-specific).
function isForcedAbsent(stageId) {
  return stageId === "auth" && state.agent === "insecure";
}

function renderFlow() {
  for (const s of STAGES) {
    const box = $(`flow-${s.id}`);
    if (!box) continue;
    const events = state.stageEvents[s.id];
    let status, subtitle;
    if (isForcedAbsent(s.id)) {
      status = "absent";
      subtitle = "no Vault login -- a static password needs no auth step";
    } else if (events.length > 0) {
      status = "complete";
      subtitle = events[events.length - 1].message || "";
    } else {
      status = "pending";
      subtitle = "—";
    }
    box.className = `flow-stage ${status}` + (state.openStage === s.id ? " open" : "");
    $(`flow-sub-${s.id}`).textContent = subtitle;
  }
  if (state.openStage) renderStageDetail(state.openStage);
}

function renderStageDetail(id) {
  const s = STAGES.find((x) => x.id === id);
  $("stage-detail-label").textContent = `${s.num}. ${s.label}`;
  $("stage-detail-what").textContent = s.what;
  $("stage-detail-why").textContent = s.why;

  const tagsEl = $("stage-detail-tags");
  tagsEl.innerHTML = "";
  for (const t of s.tags) {
    const tag = document.createElement("span");
    tag.className = "tag";
    tag.textContent = t;
    tagsEl.appendChild(tag);
  }

  // live countdown -- identity (SVID) and credential (Vault lease) only
  const liveEl = $("stage-detail-live");
  if (id === "identity" && state.identity && state.identity.spiffe_id) {
    liveEl.classList.remove("hidden");
    liveEl.textContent = `${state.identity.spiffe_id} -- SVID ${remainingLabel(state.identity.svid_expires_at)}`;
  } else if (id === "identity" && state.identity) {
    liveEl.classList.remove("hidden");
    liveEl.textContent = "no SPIFFE identity -- this agent proves nothing about itself";
  } else if (id === "credential" && state.lease) {
    liveEl.classList.remove("hidden");
    liveEl.textContent = state.lease.revoked
      ? `${state.lease.lease_role || "credential"} / ${shortLease(state.lease.lease_id)} — revoked`
      : `${state.lease.lease_role || "credential"} / ${shortLease(state.lease.lease_id)} — ${remainingLabel(state.lease.expires_at)}`;
  } else {
    liveEl.classList.add("hidden");
  }

  // scope, credential stage only
  if (id === "credential") {
    const scope = (state.lease && state.lease.scope) || [];
    if (scope.length) {
      const list = document.createElement("ul");
      list.className = "scope-list";
      for (const sc of scope) {
        const li = document.createElement("li");
        li.className = sc.allowed ? "allowed" : "denied";
        li.textContent = `${sc.allowed ? "✓" : "✗"} ${sc.action} ${sc.resource}`;
        list.appendChild(li);
      }
      liveEl.appendChild(list);
      liveEl.classList.remove("hidden");
    }
  }

  // correlation -- the "audit-ready" proof point, approval stage only,
  // deliberately NOT cleared by a later revoke (see applyEvents)
  const corrBlock = $("stage-detail-correlation");
  if (id === "approval" && state.agent !== "insecure" && state.correlation) {
    corrBlock.classList.remove("hidden");
    $("corr-approver").textContent = state.correlation.approved_by || "—";
    $("corr-spiffe").textContent = state.correlation.spiffe_id || "—";
    $("corr-lease").textContent = shortLease(state.correlation.lease_id);
  } else {
    corrBlock.classList.add("hidden");
  }

  // live TTL meter + revoke button, credential stage only
  const meterWrap = $("stage-detail-meter-wrap");
  const revokeBtn = $("revoke-btn");
  if (id === "credential" && state.lease && !state.lease.revoked) {
    meterWrap.classList.remove("hidden");
    revokeBtn.classList.remove("hidden");
  } else {
    meterWrap.classList.add("hidden");
    revokeBtn.classList.add("hidden");
  }

  // this run
  const logEl = $("stage-detail-log");
  logEl.innerHTML = "";
  const events = state.stageEvents[id] || [];
  if (events.length === 0) {
    logEl.innerHTML = '<li class="tile-sub">nothing yet this run</li>';
  }
  for (const e of events) {
    const li = document.createElement("li");
    const time = document.createElement("time");
    time.textContent = fmtTime(e.ts || Date.now() / 1000);
    const text = document.createElement("span");
    text.textContent = e.message || e.type;
    li.append(time, text);
    logEl.appendChild(li);
  }
}

// Local ticking clock for live countdowns -- purely cosmetic, driven off
// the `expires_at`/`svid_expires_at` the agent already sent. Touches only
// the stage box subtitle (always) and the detail drawer (only when open),
// never re-derives status from a timer -- a stage only completes on a
// real event.
function tickMeter() {
  if (state.lease && !state.lease.revoked && state.lease.expires_at) {
    const remaining = Math.max(0, state.lease.expires_at - Date.now() / 1000);
    const subEl = $("flow-sub-credential");
    if (subEl) subEl.textContent = `${state.lease.lease_role || "credential"} -- ${remainingLabel(state.lease.expires_at)}`;
    if (state.openStage === "credential") {
      const total = state.lease.ttl_seconds || 180;
      const frac = Math.max(0, Math.min(1, remaining / total));
      const meter = $("lease-meter");
      meter.style.width = `${frac * 100}%`;
      meter.className = "meter-fill" + (frac < 0.15 ? " critical" : frac < 0.4 ? " warning" : "");
    }
    if (remaining <= 0) {
      state.lease.revoked = true;
      renderFlow();
    }
  }
  if (state.openStage === "identity" || state.openStage === "credential") renderStageDetail(state.openStage);
}
setInterval(tickMeter, 500);

// Poll server state so a page refresh mid-demo doesn't lose the log or
// the flow panel's progress.
async function pollState() {
  try {
    const s = await j("GET", "/api/state");
    // Only backfill on first load; live updates come from direct responses.
    if ($("event-log").children.length === 0) {
      for (const e of s.log) {
        logEvent(e);
        const stageIds = STAGE_BY_TYPE[e.type] || [];
        for (const id of stageIds) state.stageEvents[id].push(e);
        if (e.type === "identity") state.identity = e;
        if (e.type === "credential_issued") {
          state.lease = e;
          if (e.approval) state.correlation = { ...e.approval, lease_id: e.lease_id, ts: e.ts };
        }
        if (e.type === "credential_revoked" && state.lease && state.lease.lease_id === e.lease_id) {
          state.lease = { ...state.lease, revoked: true };
        }
      }
      renderFlow();
    }
  } catch (_) {
    /* storefront/agents still coming up -- ignore and retry */
  }
}

(async function init() {
  buildFlowDOM();
  renderSuggestions();
  await loadCustomers();
  await loadProducts();
  await pollState();
  renderFlow();
})();
