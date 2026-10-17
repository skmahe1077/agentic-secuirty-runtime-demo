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

// The Security Flow panel: a dark stage-column diagram (Identity ->
// Authenticate -> Approval -> Credential -> Execute), each column holding
// one or more real actor-cards, with a pulse that travels card-to-card as
// real events arrive (see playTurnAnimation below). One source of truth
// for both the graph and the detail drawer -- content lives here, not in
// index.html. A card's `eventTypes` is what actually lights it up; no
// card is faked active by a timer. Identity's cards are the exception --
// they're also kept live by polling /api/state's per-agent status (see
// pollState), so both registered agents show real data even before any
// message is sent, not just whichever one answered the last turn.
const STAGES = [
  {
    id: "identity", num: 1, label: "Identity", icon: "🪪",
    what: "SPIRE issues the handling agent pod a short-lived JWT-SVID over the SPIFFE Workload API, written to disk by the spiffe-helper sidecar. order-agent and refund-agent are two genuinely separate identities -- not one agent with a mode switch -- each registered in Vault's own Agent Registry. The legacy agent skips this step entirely: no identity, just a password baked into its environment.",
    why: "A real workload identity exists before the agent ever calls Vault -- it isn't minted on the fly or typed in by anyone. Both agents exist whether or not this turn used them.",
    tags: ["SPIRE", "JWT-SVID", "Agent Registry"],
    cards: [
      { id: "order-agent", agentKey: "order", label: "order-agent", icon: "🤖", sub: "read-only", modes: ["secure"] },
      { id: "refund-agent", agentKey: "refund", label: "refund-agent", icon: "🤖", sub: "can refund", modes: ["secure"] },
      { id: "legacy-agent", agentKey: "insecure", label: "Legacy Agent", icon: "🤖", sub: "static password", modes: ["insecure"] },
    ],
  },
  {
    id: "authenticate", num: 2, label: "Authenticate", icon: "🔑", eventTypes: ["auth_completed"],
    what: "The agent presents its SVID as a Bearer token to Vault's native auth/spiffe method, which verifies the signature and issues a short-lived Vault token. The legacy agent has no equivalent step -- a static password needs no auth round trip.",
    why: "No password, no API key -- identity is the credential. A workload with a different identity is refused outright.",
    tags: ["auth/spiffe", "Vault Enterprise"],
    cards: [{ id: "vault-auth", label: "Vault", icon: "🔒", sub: "auth/spiffe" }],
  },
  {
    id: "approval", num: 3, label: "Approval", icon: "🧑‍⚖️", eventTypes: ["approval_requested", "approval_granted"],
    what: "Refunds over £100 pause here for a named human to approve before any credential is minted; the approval becomes metadata on a freshly-minted Vault child token. Under the threshold, this stage is bypassed entirely -- shown as a bypass arc, not skipped silently.",
    why: "Human intent and agent action are tied to the same auditable event -- not two logs to stitch together by hand.",
    tags: ["human-in-the-loop", "Vault child token"],
    cards: [{ id: "vault-approval", label: "Vault", icon: "🔒", sub: "human sign-off" }],
  },
  {
    id: "credential", num: 4, label: "Credential", icon: "🔐", eventTypes: ["credential_issued", "credential_revoked"],
    what: "Vault's database secrets engine mints a brand-new PostgreSQL role, scoped to exactly what the task needs, with a 3-minute TTL. The legacy agent's credential is a static Kubernetes Secret instead -- no lease, no expiry, no revoke.",
    why: "The credential is task-scoped and self-destructing -- not a standing password that outlives the task.",
    tags: ["database secrets engine", "180s TTL", "least privilege"],
    cards: [{ id: "vault-credential", label: "Vault", icon: "🔒", sub: "database secrets engine" }],
  },
  {
    id: "execute", num: 5, label: "Execute", icon: "🗄️", eventTypes: ["refund_issued", "denied", "scope_violation"],
    what: "The scoped credential runs exactly one query -- PostgreSQL itself enforces the boundary, not application logic. Ask for something outside scope (another customer's PII, a refund the role has no grant for) and the database refuses it, the same mechanism every time.",
    why: "The boundary is enforced by the database's own grants -- not a special case in the agent's code that someone could forget to add.",
    tags: ["PostgreSQL grants"],
    cards: [{ id: "database", label: "Database", icon: "🗄️", sub: "PostgreSQL" }],
  },
];
// Flat list of every card across every stage -- the unit the graph/pulse
// actually operates on (a stage is just how cards are grouped visually).
const CARDS = STAGES.flatMap((s) => s.cards.map((c) => ({ ...c, stageId: s.id })));
const CARD_BY_TYPE = {};
for (const s of STAGES) for (const t of s.eventTypes || []) {
  // Non-identity stages have exactly one card; events light that card.
  CARD_BY_TYPE[t] = s.cards[0].id;
}

const state = {
  customerId: 1,
  agent: "secure",
  identity: null,       // last identity event
  activeAgent: null,     // "order" | "refund" -- which identity card handled the last turn
  agentStatus: { order: null, refund: null, insecure: null }, // live /api/state polling, see pollState
  lease: null,           // last credential_issued event (cleared on revoke/expiry)
  correlation: null,     // last approved credential's {approved_by, spiffe_id, lease_id, approval_id, ts} -- NOT cleared on revoke, see applyEvents
  anyActivity: false,    // has at least one real event happened this run
  cardEvents: Object.fromEntries(CARDS.map((c) => [c.id, []])),
  openStage: null,        // which card's detail drawer is open, if any
  pendingApproval: null, // {approval_id, thread_id}
  threadId: "demo",
};

function _agentKeyFromSpiffeId(spiffeId) {
  if (!spiffeId) return null;
  const sa = spiffeId.split("/").pop();
  if (sa === "ai-order-agent") return "order";
  if (sa === "ai-support-agent-secure") return "refund";
  return null;
}

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
  // Two pickers, same options -- the Security Flow tab's (demo-controls)
  // and the one inside the chat widget itself, so a real visitor never
  // has to leave the chat to say who they are.
  for (const sel of [$("customer-picker"), $("chat-customer-picker")]) {
    sel.innerHTML = "";
    for (const c of customers) {
      const opt = document.createElement("option");
      opt.value = c.customer_id;
      opt.textContent = c.name;
      sel.appendChild(opt);
    }
    sel.value = state.customerId;
  }
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
  state.activeAgent = null;
  state.correlation = null;
  state.openStage = null;
  state.anyActivity = false;
  for (const c of CARDS) state.cardEvents[c.id] = [];
  $("stage-detail").classList.add("hidden");
}

$("reset-btn").addEventListener("click", async () => {
  await j("POST", "/api/admin/reset");
  resetFlowState();
  $("chat-log").innerHTML = "";
  $("event-stream").innerHTML = "";
  renderStageGraph();
  renderSuggestions();
});

function _setCustomerId(id) {
  state.customerId = id;
  $("customer-picker").value = id;
  $("chat-customer-picker").value = id;
}
$("customer-picker").addEventListener("change", (e) => {
  _setCustomerId(parseInt(e.target.value, 10));
});
$("chat-customer-picker").addEventListener("change", (e) => {
  _setCustomerId(parseInt(e.target.value, 10));
});
$("agent-picker").addEventListener("change", (e) => {
  state.agent = e.target.value;
  resetFlowState();
  renderStageGraph();
  drawConnectors(); // which cards are visible changed (legacy vs. the two real agents)
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

// Shared per-event bookkeeping used by both a live turn (applyEvents) and
// the one-time backfill from /api/state's log (pollState) -- one place
// that knows how to route an event to its card and update derived state,
// so the two can't drift.
function _identityCardIdFor(spiffeId) {
  const key = _agentKeyFromSpiffeId(spiffeId);
  if (key === "refund") return "refund-agent";
  if (key === "order") return "order-agent";
  return "legacy-agent"; // no spiffe_id -- the static-password agent
}

function _absorbEvent(e) {
  const cardId = e.type === "identity" ? _identityCardIdFor(e.spiffe_id) : CARD_BY_TYPE[e.type];
  if (cardId) state.cardEvents[cardId].push(e);

  if (e.type === "identity") {
    state.identity = e;
    state.activeAgent = _agentKeyFromSpiffeId(e.spiffe_id);
  }
  if (e.type === "credential_issued") {
    state.lease = e;
    if (e.approval) {
      // Deliberately NOT cleared on revoke or expiry below: the
      // credential is ephemeral, the record of who authorised it is not.
      // That asymmetry is what the Credential card's detail shows.
      state.correlation = { ...e.approval, lease_id: e.lease_id, ts: e.ts || Date.now() / 1000 };
    }
  }
  if (e.type === "credential_revoked" && state.lease && state.lease.lease_id === e.lease_id) {
    state.lease = { ...state.lease, revoked: true };
  }
}

function applyEvents(events) {
  for (const e of events) {
    logEvent(e);
    _absorbEvent(e);
  }
  if (events.length) state.anyActivity = true;
  renderStageGraph();
  playTurnAnimation(events); // fire-and-forget visual pulse, over already-settled text
}

// Actor tag for the terminal-style event stream -- derived from the
// event's own type, same real data the stage cards use, just labeled the
// way a log line would be.
function _actorTag(e) {
  if (e.type === "identity") return "agent";
  if (["auth_completed", "credential_issued", "credential_revoked", "approval_requested", "approval_granted"].includes(e.type)) return "vault";
  if (["refund_issued", "denied", "scope_violation"].includes(e.type)) return "postgres";
  return "agent";
}

function logEvent(e) {
  const log = $("event-stream");
  const line = document.createElement("div");
  line.className = `stream-line ${dotClassFor(e)}`;
  const time = document.createElement("span");
  time.className = "stream-time";
  time.textContent = `[${fmtTime(e.ts || Date.now() / 1000)}]`;
  const actor = document.createElement("span");
  actor.className = `stream-actor stream-actor-${_actorTag(e)}`;
  actor.textContent = `[${_actorTag(e)}]`;
  const text = document.createElement("span");
  text.className = "stream-text";
  text.textContent = e.message || e.type;
  line.append(time, actor, text);
  log.appendChild(line); // terminal-style: newest at the bottom, auto-scrolled
  log.scrollTop = log.scrollHeight;
  while (log.children.length > 60) log.removeChild(log.firstChild);
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

function buildStageGraphDOM() {
  const graph = $("stage-graph");
  graph.innerHTML = "";
  for (const stage of STAGES) {
    const col = document.createElement("div");
    col.className = "stage-col";
    col.id = `stagecol-${stage.id}`;
    const head = document.createElement("div");
    head.className = "stage-col-head";
    head.innerHTML = `<span class="stage-col-num">${stage.num}</span><span class="stage-col-label">${stage.label}</span>`;
    col.appendChild(head);
    const cardsWrap = document.createElement("div");
    cardsWrap.className = "stage-col-cards";
    for (const card of stage.cards) {
      const el = document.createElement("div");
      el.className = "flow-card";
      el.id = `card-${card.id}`;
      el.innerHTML = `
        <div class="flow-card-icon">${card.icon}</div>
        <div class="flow-card-body">
          <div class="flow-card-label">${card.label}</div>
          <div class="flow-card-sub" id="card-sub-${card.id}">${card.sub || "—"}</div>
          <div class="flow-card-tag hidden" id="card-tag-${card.id}"></div>
        </div>`;
      el.addEventListener("click", () => openStageDetail(card.id));
      cardsWrap.appendChild(el);
    }
    col.appendChild(cardsWrap);
    graph.appendChild(col);
  }

  // Connector lines -- every card in stage N to every card in stage N+1,
  // not one arrow per column. Identity has two cards (order-agent,
  // refund-agent); both get their own line converging into Vault, so the
  // diagram shows both real registered agents actually connecting to
  // Authenticate, not just a generic column-to-column marker. Positions
  // are computed after layout in drawConnectors() -- built empty here.
  const svgNS = "http://www.w3.org/2000/svg";
  const connectorSvg = document.createElementNS(svgNS, "svg");
  connectorSvg.setAttribute("class", "connector-layer");
  connectorSvg.setAttribute("id", "connector-layer");
  const defs = document.createElementNS(svgNS, "defs");
  const marker = document.createElementNS(svgNS, "marker");
  marker.setAttribute("id", "connector-arrowhead");
  marker.setAttribute("viewBox", "0 0 8 8");
  marker.setAttribute("refX", "7");
  marker.setAttribute("refY", "4");
  marker.setAttribute("markerWidth", "7");
  marker.setAttribute("markerHeight", "7");
  marker.setAttribute("orient", "auto-start-reverse");
  const arrowShape = document.createElementNS(svgNS, "path");
  arrowShape.setAttribute("d", "M 0 0 L 8 4 L 0 8 z");
  arrowShape.setAttribute("class", "connector-arrowhead-fill");
  marker.appendChild(arrowShape);
  defs.appendChild(marker);
  connectorSvg.appendChild(defs);
  graph.appendChild(connectorSvg);

  // Bypass arc overlay -- shown only when a turn's real events reach
  // Credential without ever touching Approval (see updateBypassArc).
  const svg = document.createElementNS(svgNS, "svg");
  svg.setAttribute("class", "bypass-arc-layer hidden");
  svg.setAttribute("id", "bypass-arc-layer");
  const arcPath = document.createElementNS(svgNS, "path");
  arcPath.setAttribute("id", "bypass-arc-path");
  svg.appendChild(arcPath);
  graph.appendChild(svg);
  const label = document.createElement("div");
  label.className = "bypass-arc-label hidden";
  label.id = "bypass-arc-label";
  label.textContent = "bypass — under £100 threshold";
  graph.appendChild(label);

  const pulse = document.createElement("div");
  pulse.className = "graph-pulse hidden";
  pulse.id = "graph-pulse";
  graph.appendChild(pulse);

  drawConnectors();
}

// Coordinates relative to `container` via getBoundingClientRect, not
// offsetLeft/offsetTop -- cards are nested inside .stage-col, which is
// itself a positioning context (needed for the bypass arc/stage number),
// so offsetLeft on a card would be relative to the wrong ancestor.
function _rectRelativeTo(el, container) {
  const r = el.getBoundingClientRect();
  const c = container.getBoundingClientRect();
  return { left: r.left - c.left, top: r.top - c.top, width: r.width, height: r.height };
}

// Real connector lines, card to card -- every visible card in stage N to
// every visible card in stage N+1 (Identity's two agent cards both draw
// a line into Vault; every other adjacent pair is a single straight
// line). Recomputed whenever which cards are visible can change (mode
// switch) or the layout reflows (window resize).
function drawConnectors() {
  const svg = $("connector-layer");
  const graph = $("stage-graph");
  if (!svg || !graph) return;
  while (svg.lastChild && svg.lastChild.tagName !== "defs") svg.removeChild(svg.lastChild);

  for (let i = 0; i < STAGES.length - 1; i++) {
    const fromEls = STAGES[i].cards
      .filter((c) => !c.modes || c.modes.includes(state.agent))
      .map((c) => $(`card-${c.id}`))
      .filter(Boolean);
    const toEls = STAGES[i + 1].cards
      .filter((c) => !c.modes || c.modes.includes(state.agent))
      .map((c) => $(`card-${c.id}`))
      .filter(Boolean);
    for (const fromEl of fromEls) {
      const from = _rectRelativeTo(fromEl, graph);
      for (const toEl of toEls) {
        const to = _rectRelativeTo(toEl, graph);
        const x1 = from.left + from.width;
        const y1 = from.top + from.height / 2;
        const x2 = to.left - 6; // short gap so the arrowhead doesn't touch the card border
        const y2 = to.top + to.height / 2;
        const midX = (x1 + x2) / 2;
        const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
        path.setAttribute("class", "connector-line");
        path.setAttribute("marker-end", "url(#connector-arrowhead)");
        path.setAttribute("d", `M ${x1} ${y1} C ${midX} ${y1}, ${midX} ${y2}, ${x2} ${y2}`);
        svg.appendChild(path);
      }
    }
  }
}
window.addEventListener("resize", () => drawConnectors());

function openStageDetail(id) {
  state.openStage = id;
  $("stage-detail").classList.remove("hidden");
  renderStageGraph();
}
$("stage-detail-close").addEventListener("click", () => {
  state.openStage = null;
  $("stage-detail").classList.add("hidden");
  renderStageGraph();
});

function renderStageGraph() {
  const isInsecure = state.agent === "insecure";

  for (const stage of STAGES) {
    for (const card of stage.cards) {
      const el = $(`card-${card.id}`);
      if (!el) continue;

      if (card.modes && !card.modes.includes(state.agent)) {
        el.classList.add("hidden");
        continue;
      }

      const events = state.cardEvents[card.id] || [];
      let subtitle = card.sub || "—";
      let tone = "";
      let tag = null;

      if (stage.id === "identity") {
        if (card.agentKey === "insecure") {
          subtitle = state.anyActivity ? "no identity -- just a password" : card.sub;
          tone = state.anyActivity ? "absent" : "";
        } else {
          // Kept live by pollState's /api/state polling, independent of
          // whether this agent handled the last turn -- both real,
          // registered agents show real data, not just the active one.
          const live = state.agentStatus && state.agentStatus[card.agentKey];
          const active = state.activeAgent === card.agentKey;
          if (live && live.identity && live.identity.spiffe_id) {
            tone = active ? "lit" : "registered";
            subtitle = active && events.length ? events[events.length - 1].message : `${card.sub} -- registered`;
          }
          // Agent Registry's real ceiling policy -- read by the agent off
          // its own already-scoped token (see terraform/vault-config.tf),
          // not fabricated or inferred. Absent (not blank/"—") until the
          // agent has handled at least one real turn, since it's read
          // opportunistically, never via a login forced just for this.
          // Vault attaches "default"/"default-ceiling" to every identity
          // automatically -- filtered out here so the tag highlights the
          // one actually configured in terraform/agentic-iam.tf, not
          // Vault's own implicit baseline.
          const ceiling = ((live && live.registry && live.registry.ceiling_policies) || []).filter(
            (p) => p !== "default" && p !== "default-ceiling"
          );
          if (ceiling.length) tag = `ceiling: ${ceiling.join(", ")}`;
        }
      } else if (events.length) {
        subtitle = events[events.length - 1].message || "";
        tone = "lit";
      }

      // Current state, not "did this ever happen this session" -- an
      // approval that was later granted shouldn't stay stuck amber, and a
      // fresh credential after a revoke shouldn't stay stuck grey.
      const lastType = events.length ? events[events.length - 1].type : null;
      if (lastType === "approval_requested") tone = "warning";
      if (lastType === "denied" || lastType === "scope_violation" || lastType === "error") tone = "critical";
      if (lastType === "credential_revoked") tone = "revoked";

      el.className = "flow-card" + (tone ? ` ${tone}` : "") + (state.openStage === card.id ? " open" : "");
      $(`card-sub-${card.id}`).textContent = subtitle;
      const tagEl = $(`card-tag-${card.id}`);
      if (tagEl) {
        tagEl.textContent = tag || "";
        tagEl.classList.toggle("hidden", !tag);
      }
    }
  }
  if (state.openStage) renderStageDetail(state.openStage);
}

// Which identity card the pulse should visit -- whichever agent actually
// handled the last turn, or the legacy agent in insecure mode. Falls
// back to order-agent (the default-routed, least-privilege agent) before
// any turn has happened yet.
function _identityCardId() {
  if (state.agent === "insecure") return "legacy-agent";
  return state.activeAgent === "refund" ? "refund-agent" : "order-agent";
}

// Builds the sequence of cards a pulse travels through for one turn's
// real events -- each stage lights independently off its OWN event
// type(s), so Authenticate and Credential can never be conflated into
// one hop. An empty/small-talk turn just travels to the identity card
// and stops.
function hopPath(events) {
  const path = [_identityCardId()];
  if (events.some((e) => e.type === "auth_completed")) path.push("vault-auth");
  if (events.some((e) => e.type === "approval_requested" || e.type === "approval_granted")) path.push("vault-approval");
  if (events.some((e) => e.type === "credential_issued" || e.type === "credential_revoked")) path.push("vault-credential");
  if (events.some((e) => ["refund_issued", "denied", "scope_violation"].includes(e.type))) path.push("database");
  return path;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Shows/hides the bypass arc -- real conditional logic (a refund under
// the threshold genuinely never asks for approval), not decoration: a
// turn that reached Credential without ever touching Approval earns the
// arc; one that went through Approval for real does not.
function updateBypassArc(show) {
  const layer = $("bypass-arc-layer");
  const label = $("bypass-arc-label");
  const arcPath = $("bypass-arc-path");
  if (!layer || !label || !arcPath) return;
  if (!show) {
    layer.classList.add("hidden");
    label.classList.add("hidden");
    return;
  }
  const from = $("stagecol-authenticate");
  const to = $("stagecol-credential");
  if (!from || !to) return;
  const x1 = from.offsetLeft + from.offsetWidth / 2;
  const x2 = to.offsetLeft + to.offsetWidth / 2;
  arcPath.setAttribute("d", `M ${x1} 38 Q ${(x1 + x2) / 2} 18 ${x2} 38`);
  label.style.left = `${(x1 + x2) / 2}px`;
  layer.classList.remove("hidden");
  label.classList.remove("hidden");
}

// A paced *replay* of the real event sequence, not a live network
// capture -- the backend events for a turn all arrive in one HTTP
// response, not a stream. Runs concurrently with the instant text/state
// update above; this is purely the "watch it travel" visual on top.
async function playTurnAnimation(events) {
  if (!events.length) return;
  const path = hopPath(events);
  const pulse = $("graph-pulse");
  if (!pulse) return;

  updateBypassArc(path.includes("vault-credential") && !path.includes("vault-approval"));

  pulse.classList.remove("hidden");
  for (const cardId of path) {
    const cardEl = $(`card-${cardId}`);
    if (!cardEl) continue;
    pulse.style.left = `${cardEl.offsetLeft + cardEl.offsetWidth / 2}px`;
    pulse.style.top = `${cardEl.offsetTop + cardEl.offsetHeight / 2}px`;
    cardEl.classList.add("pulse-hit");
    await sleep(420);
    cardEl.classList.remove("pulse-hit");
  }
  await sleep(450);
  pulse.classList.add("hidden");
}

function renderStageDetail(cardId) {
  const card = CARDS.find((c) => c.id === cardId);
  if (!card) return;
  const stage = STAGES.find((s) => s.id === card.stageId);
  $("stage-detail-label").textContent = `${card.icon} ${card.label}`;
  $("stage-detail-what").textContent = stage.what;
  $("stage-detail-why").textContent = stage.why;

  const tagsEl = $("stage-detail-tags");
  tagsEl.innerHTML = "";
  for (const t of stage.tags) {
    const tag = document.createElement("span");
    tag.className = "tag";
    tag.textContent = t;
    tagsEl.appendChild(tag);
  }

  // live countdown -- identity (SVID, both real agents) and credential
  // (Vault lease) only
  const liveEl = $("stage-detail-live");
  liveEl.innerHTML = "";
  if (stage.id === "identity" && card.agentKey !== "insecure") {
    const live = state.agentStatus && state.agentStatus[card.agentKey];
    liveEl.classList.remove("hidden");
    liveEl.textContent =
      live && live.identity && live.identity.spiffe_id
        ? `${live.identity.spiffe_id} -- SVID ${remainingLabel(live.identity.svid_expires_at)}`
        : "registered in the Agent Registry -- no live status yet";
  } else if (card.id === "legacy-agent" && state.anyActivity) {
    liveEl.classList.remove("hidden");
    liveEl.textContent = "no SPIFFE identity -- this agent proves nothing about itself";
  } else if (card.id === "vault-credential" && state.lease) {
    liveEl.classList.remove("hidden");
    liveEl.textContent = state.lease.revoked
      ? `${state.lease.lease_role || "credential"} / ${shortLease(state.lease.lease_id)} — revoked`
      : `${state.lease.lease_role || "credential"} / ${shortLease(state.lease.lease_id)} — ${remainingLabel(state.lease.expires_at)}`;
  } else {
    liveEl.classList.add("hidden");
  }

  // scope, Credential card only
  if (card.id === "vault-credential") {
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

  // correlation -- the "audit-ready" proof point, Credential card only,
  // deliberately NOT cleared by a later revoke (see _absorbEvent)
  const corrBlock = $("stage-detail-correlation");
  if (card.id === "vault-credential" && state.agent !== "insecure" && state.correlation) {
    corrBlock.classList.remove("hidden");
    $("corr-approver").textContent = state.correlation.approved_by || "—";
    $("corr-spiffe").textContent = state.correlation.spiffe_id || "—";
    $("corr-lease").textContent = shortLease(state.correlation.lease_id);
  } else {
    corrBlock.classList.add("hidden");
  }

  // live TTL meter + revoke button, Credential card only
  const meterWrap = $("stage-detail-meter-wrap");
  const revokeBtn = $("revoke-btn");
  if (card.id === "vault-credential" && state.lease && !state.lease.revoked) {
    meterWrap.classList.remove("hidden");
    revokeBtn.classList.remove("hidden");
  } else {
    meterWrap.classList.add("hidden");
    revokeBtn.classList.add("hidden");
  }

  // this run
  const logEl = $("stage-detail-log");
  logEl.innerHTML = "";
  const events = state.cardEvents[cardId] || [];
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
// the card subtitle (always) and the detail drawer (only when open),
// never re-derives status from a timer -- a card only lights up on a
// real event.
function tickMeter() {
  if (state.lease && !state.lease.revoked && state.lease.expires_at) {
    const remaining = Math.max(0, state.lease.expires_at - Date.now() / 1000);
    const subEl = $("card-sub-vault-credential");
    if (subEl) subEl.textContent = `${state.lease.lease_role || "credential"} -- ${remainingLabel(state.lease.expires_at)}`;
    if (state.openStage === "vault-credential") {
      const total = state.lease.ttl_seconds || 180;
      const frac = Math.max(0, Math.min(1, remaining / total));
      const meter = $("lease-meter");
      meter.style.width = `${frac * 100}%`;
      meter.className = "meter-fill" + (frac < 0.15 ? " critical" : frac < 0.4 ? " warning" : "");
    }
    if (remaining <= 0) {
      state.lease.revoked = true;
      renderStageGraph();
    }
  }
  if (state.openStage) renderStageDetail(state.openStage);
}
setInterval(tickMeter, 500);

// Poll server state so a page refresh mid-demo doesn't lose the log or
// the flow panel's progress -- and, now, so BOTH registered agents' real
// identity stay visible at all times, not just whichever one answered
// the last chat turn. api_state() (app/storefront/main.py) already
// proxies each backend's own /status endpoint for exactly this.
async function pollState() {
  try {
    const s = await j("GET", "/api/state");
    state.agentStatus = s.agents || {};
    // Only backfill the log/cardEvents once; live updates come from
    // direct chat/resume/revoke responses via applyEvents.
    if ($("event-stream").children.length === 0) {
      for (const e of s.log) {
        logEvent(e);
        _absorbEvent(e);
      }
      if (s.log.length) state.anyActivity = true;
    }
    renderStageGraph();
  } catch (_) {
    /* storefront/agents still coming up -- ignore and retry */
  }
}
setInterval(pollState, 4000);

(async function init() {
  buildStageGraphDOM();
  renderSuggestions();
  await loadCustomers();
  await loadProducts();
  await pollState();
  renderStageGraph();
})();
