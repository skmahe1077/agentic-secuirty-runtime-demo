// Nimbus Store frontend. No build step, no framework -- this runs
// unmodified off a static file mount so there's one less thing to break on
// stage.
//
// Event contract (produced by the agent services, relayed verbatim by the
// storefront, consumed here):
//   { type: "identity", spiffe_id, svid_expires_at, ttl_seconds, message }
//   { type: "credential_issued", lease_id, lease_role, expires_at, ttl_seconds,
//     scope: [{resource, action, allowed}],
//     approval: {approval_id, approved_by, spiffe_id} | null, message }
//   { type: "credential_revoked", lease_id, message }
//   { type: "denied", resource, message }
//   { type: "approval_requested", approval_id, amount_pence, message }
//   { type: "approval_granted", approval_id, approved_by, message }
//   { type: "refund_issued", order_id, amount_pence, message }
//   { type: "info" | "error", message }
// Every event also carries `ts` (epoch seconds), added by the storefront if
// the agent didn't set one.

const state = {
  customerId: 1,
  agent: "secure",
  identity: null,       // last identity event
  lease: null,           // last credential_issued event (cleared on revoke/expiry)
  correlation: null,     // last approved credential's {approved_by, spiffe_id, lease_id, approval_id, ts} -- NOT cleared on revoke, see applyEvents
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

// ---------- catalog / orders ----------

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
    card.innerHTML = `<div class="name">${p.name}</div><div class="price">${money(p.price_pence)} · ${p.stock} in stock</div>`;
    grid.appendChild(card);
  }
}

async function loadOrders() {
  const orders = await j("GET", `/api/orders?customer_id=${state.customerId}`);
  const list = $("orders");
  list.innerHTML = "";
  for (const o of orders) {
    const row = document.createElement("div");
    row.className = "order-row";
    row.innerHTML = `
      <span>#${o.order_id} · ${o.product_name} · ${money(o.total_pence)}</span>
      <span class="status-badge status-${o.status}">${o.status}</span>`;
    list.appendChild(row);
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
}

$("chat-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const input = $("chat-input");
  const message = input.value.trim();
  if (!message) return;
  addChatBubble(message, "user");
  input.value = "";
  try {
    const resp = await j("POST", "/api/support/chat", {
      customer_id: state.customerId,
      agent: state.agent,
      message,
      thread_id: state.threadId,
    });
    handleAgentResponse(resp);
  } catch (err) {
    addChatBubble(`(error contacting agent: ${err})`, "agent", true);
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
  loadOrders();
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
    const resp = await j("POST", "/api/admin/revoke", { agent: state.agent });
    applyEvents(resp.events || []);
  } catch (err) {
    addChatBubble(`(revoke failed: ${err})`, "agent", true);
  }
});

$("reset-btn").addEventListener("click", async () => {
  await j("POST", "/api/admin/reset");
  state.lease = null;
  state.identity = null;
  state.correlation = null;
  $("chat-log").innerHTML = "";
  renderPanel();
  loadOrders();
});

$("customer-picker").addEventListener("change", (e) => {
  state.customerId = parseInt(e.target.value, 10);
  loadOrders();
});
$("agent-picker").addEventListener("change", (e) => {
  state.agent = e.target.value;
  state.lease = null;
  state.identity = null;
  state.correlation = null;
  renderPanel();
});

// ---------- Identity & Access panel ----------

function applyEvents(events) {
  for (const e of events) {
    logEvent(e);
    if (e.type === "identity") state.identity = e;
    if (e.type === "credential_issued") {
      state.lease = e;
      if (e.approval) {
        // Deliberately NOT cleared on revoke or expiry below: the
        // credential is ephemeral, the record of who authorised it is
        // not. That asymmetry is the "audit-ready" claim this tile makes.
        state.correlation = { ...e.approval, lease_id: e.lease_id, ts: e.ts || Date.now() / 1000 };
      }
    }
    if (e.type === "credential_revoked" && state.lease && state.lease.lease_id === e.lease_id) {
      state.lease = { ...state.lease, revoked: true };
    }
  }
  renderPanel();
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

function renderPanel() {
  // identity tile
  if (state.identity) {
    $("identity-value").textContent = state.identity.spiffe_id || "static credential (no workload identity)";
    $("identity-sub").textContent = state.identity.spiffe_id
      ? `SVID ${remainingLabel(state.identity.svid_expires_at)}`
      : "no SPIFFE identity -- this agent proves nothing about itself";
  } else {
    $("identity-value").textContent = "—";
    $("identity-sub").textContent = "";
  }

  // lease tile
  const revokeBtn = $("revoke-btn");
  if (state.lease && !state.lease.revoked) {
    $("lease-value").textContent = `${state.lease.lease_role || "credential"} / ${shortLease(state.lease.lease_id)}`;
    $("lease-sub").textContent = remainingLabel(state.lease.expires_at);
    revokeBtn.classList.remove("hidden");
  } else if (state.lease && state.lease.revoked) {
    $("lease-value").textContent = `${shortLease(state.lease.lease_id)} — revoked`;
    $("lease-sub").textContent = "credential no longer exists";
    $("lease-meter").style.width = "0%";
    $("lease-meter").className = "meter-fill critical";
    revokeBtn.classList.add("hidden");
  } else {
    $("lease-value").textContent = "—";
    $("lease-sub").textContent = "no standing credential held";
    $("lease-meter").style.width = "0%";
    revokeBtn.classList.add("hidden");
  }

  // correlation tile -- the talk's "audit-ready controls" proof point now
  // lives here instead of in a Vault audit-log reveal (see
  // app/agent/src/agent/vault.py's get_db_credentials)
  const corrTile = $("tile-correlation");
  if (state.agent === "insecure") {
    corrTile.classList.remove("hidden");
    $("corr-approver").textContent = "—";
    $("corr-spiffe").textContent = "—";
    $("corr-lease").textContent = "—";
    $("corr-approval-id").textContent = "—";
    $("corr-ts").textContent = "no correlation possible -- this credential has no identity and no approval binding";
  } else if (state.correlation) {
    corrTile.classList.remove("hidden");
    $("corr-approver").textContent = state.correlation.approved_by || "—";
    $("corr-spiffe").textContent = state.correlation.spiffe_id || "—";
    $("corr-lease").textContent = shortLease(state.correlation.lease_id);
    $("corr-approval-id").textContent = state.correlation.approval_id || "—";
    $("corr-ts").textContent = fmtTime(state.correlation.ts);
  } else {
    corrTile.classList.add("hidden");
  }

  // scope tile
  const scopeList = $("scope-list");
  scopeList.innerHTML = "";
  const scope = (state.lease && state.lease.scope) || [];
  if (scope.length === 0) {
    scopeList.innerHTML = '<li class="tile-sub">no active scope</li>';
  }
  for (const s of scope) {
    const li = document.createElement("li");
    li.className = s.allowed ? "allowed" : "denied";
    li.textContent = `${s.allowed ? "✓" : "✗"} ${s.action} ${s.resource}`;
    scopeList.appendChild(li);
  }
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

// Local ticking clock for the lease meter -- purely cosmetic, driven off
// the `expires_at` + `ttl_seconds` the agent sent with credential_issued.
function tickMeter() {
  if (state.lease && !state.lease.revoked && state.lease.expires_at) {
    const total = state.lease.ttl_seconds || 180;
    const remaining = Math.max(0, state.lease.expires_at - Date.now() / 1000);
    const frac = Math.max(0, Math.min(1, remaining / total));
    const meter = $("lease-meter");
    meter.style.width = `${frac * 100}%`;
    meter.className = "meter-fill" + (frac < 0.15 ? " critical" : frac < 0.4 ? " warning" : "");
    $("lease-sub").textContent = remainingLabel(state.lease.expires_at);
    if (remaining <= 0) {
      state.lease.revoked = true;
      renderPanel();
    }
  }
  if (state.identity && state.identity.svid_expires_at) {
    $("identity-sub").textContent = state.identity.spiffe_id
      ? `SVID ${remainingLabel(state.identity.svid_expires_at)}`
      : "";
  }
}
setInterval(tickMeter, 500);

// Poll server state so a page refresh mid-demo doesn't lose the log.
async function pollState() {
  try {
    const s = await j("GET", "/api/state");
    // Only backfill the log on first load; live updates come from direct responses.
    if ($("event-log").children.length === 0) {
      for (const e of s.log) logEvent(e);
      const lastApproved = [...s.log].reverse()
        .find((e) => e.type === "credential_issued" && e.approval);
      if (lastApproved) {
        state.correlation = { ...lastApproved.approval, lease_id: lastApproved.lease_id, ts: lastApproved.ts };
        renderPanel();
      }
    }
  } catch (_) {
    /* storefront/agents still coming up -- ignore and retry */
  }
}

(async function init() {
  await loadCustomers();
  await loadProducts();
  await loadOrders();
  await pollState();
  renderPanel();
})();
