"""A regex-based stand-in for the LangChain agent.

This is what actually runs in this sandbox (no ANTHROPIC_API_KEY available
to exercise `langchain_engine.py` against a live model) and what CI/local
verification should keep running against, since it costs nothing and
exercises the exact same `actions.py` / `vault.py` code paths the real
LangChain agent uses. Swap `AGENT_ENGINE=langchain` for the talk itself.
"""
from __future__ import annotations

import re

import actions
import approval
from config import Settings
from engine_base import AgentTurnResult

_REFUND_RE = re.compile(r"refund.*?#?\s*(\d{3,6})", re.IGNORECASE)
_ORDER_RE = re.compile(
    r"(?:order|status|look ?up|where is|find|track(?:ing)?|when will|has.*shipped)"
    r".*?#?\s*(\d{3,6})",
    re.IGNORECASE,
)
_CUSTOMER_RE = re.compile(r"customer\s*#?\s*(\d{1,6})", re.IGNORECASE)
_PII_HINT_RE = re.compile(r"phone|email|contact|address|pii", re.IGNORECASE)

# Intent words with no order number attached yet -- e.g. a suggestion chip's
# canned "Request a refund" / "Check my order status", or just a customer
# who hasn't said which order. Checked only after _REFUND_RE/_ORDER_RE have
# already had a chance to match a message that DOES carry a number.
_REFUND_INTENT_RE = re.compile(r"\brefund\b", re.IGNORECASE)
_ORDER_INTENT_RE = re.compile(r"\b(?:order|status|track(?:ing)?)\b", re.IGNORECASE)
# A bare reply to "which order number?" -- "1042", "#1042", "it's 1042".
_BARE_NUMBER_RE = re.compile(r"#?\s*(\d{3,6})")

_GREETING_RE = re.compile(r"^\s*(?:hi|hello|hey|good (?:morning|afternoon|evening))\b", re.IGNORECASE)
_THANKS_RE = re.compile(r"\b(?:thanks|thank you|cheers|appreciate it)\b", re.IGNORECASE)
_FAREWELL_RE = re.compile(r"^\s*(?:bye|goodbye|see ya|that'?s all|that is all)\b", re.IGNORECASE)
_HELP_RE = re.compile(r"\b(?:help|what can you do|how does this work)\b", re.IGNORECASE)

_GREETING_REPLY = (
    "Hi, I'm the Mahi Stores support agent -- I can check an order's status "
    "(\"where's order #1042\") or process a refund (\"refund order #1042\")."
)
_HELP_REPLY = (
    "I can look up an order's status (\"track order #1042\"), or process a refund "
    "(\"refund order #1042\"). Browsing the catalog itself happens on the page -- "
    "I handle anything to do with an order you've already placed."
)
_FALLBACK_REPLY = (
    "I didn't catch an order number in that. Try \"status of order #1042\" or "
    "\"refund order #1042\" -- or just say hi!"
)


class DeterministicEngine:
    def __init__(self, settings: Settings, session):
        self.settings = settings
        self.session = session
        self.enforce_ownership = settings.agent_mode == "secure"
        self._pending: dict[str, dict] = {}
        # thread_id -> "refund" | "lookup": an intent recognized with no
        # order number yet attached, awaiting the customer's next message.
        self._pending_intent: dict[str, str] = {}

    def handle_message(self, customer_id: int, message: str, thread_id: str) -> AgentTurnResult:
        self.session.begin_turn()
        pending_kind = self._pending_intent.pop(thread_id, None)
        if pending_kind:
            m = _REFUND_RE.search(message) or _ORDER_RE.search(message) or _BARE_NUMBER_RE.search(message)
            if m:
                order_id = int(m.group(1))
                if pending_kind == "refund":
                    return self._start_refund(order_id, message, customer_id, thread_id)
                reply, events = actions.lookup_order(order_id, customer_id, self.session, self.enforce_ownership)
                return AgentTurnResult(reply=reply, events=events)
            # no number in the reply -- keep waiting rather than drop the intent
            self._pending_intent[thread_id] = pending_kind
            return AgentTurnResult(reply="I still need an order number -- something like \"#1042\".", events=[])

        m = _REFUND_RE.search(message)
        if m:
            return self._start_refund(int(m.group(1)), message, customer_id, thread_id)

        m = _CUSTOMER_RE.search(message)
        if m and _PII_HINT_RE.search(message):
            reply, events = actions.lookup_customer_pii(int(m.group(1)), self.session, self.settings.agent_name)
            return AgentTurnResult(reply=reply, events=events)

        m = _ORDER_RE.search(message)
        if m:
            reply, events = actions.lookup_order(int(m.group(1)), customer_id, self.session, self.enforce_ownership)
            return AgentTurnResult(reply=reply, events=events)

        # Intent is clear but no order number was given yet (e.g. a
        # suggestion chip's canned "Request a refund" / "Check my order
        # status") -- ask for it instead of falling through to the generic
        # fallback reply below.
        if _REFUND_INTENT_RE.search(message):
            self._pending_intent[thread_id] = "refund"
            return AgentTurnResult(reply="Sure -- which order number would you like refunded?", events=[])
        if _ORDER_INTENT_RE.search(message):
            self._pending_intent[thread_id] = "lookup"
            return AgentTurnResult(reply="Sure -- which order number would you like me to check?", events=[])

        # Small talk -- none of these touch the database or Vault, so they
        # carry no credential/identity events; checked last so a greeting
        # that also mentions an order number ("hi, can you refund #1042?")
        # still triggers the real action above instead of a pleasantry.
        if _GREETING_RE.search(message):
            return AgentTurnResult(reply=_GREETING_REPLY, events=[])
        if _FAREWELL_RE.search(message):
            return AgentTurnResult(reply="Take care -- come back any time you need an order looked into.", events=[])
        if _THANKS_RE.search(message):
            return AgentTurnResult(reply="You're welcome -- anything else I can look into?", events=[])
        if _HELP_RE.search(message):
            return AgentTurnResult(reply=_HELP_REPLY, events=[])

        return AgentTurnResult(reply=_FALLBACK_REPLY, events=[])

    def _start_refund(self, order_id: int, message: str, customer_id: int, thread_id: str) -> AgentTurnResult:
        try:
            amount = actions.peek_order_total_pence(order_id, self.session)
        except Exception as exc:  # noqa: BLE001
            return AgentTurnResult(reply=f"I couldn't reach the order database: {exc}", events=[])

        if amount is None:
            return AgentTurnResult(reply=f"I can't find order #{order_id}.", events=[])

        if amount > self.settings.refund_approval_threshold_pence:
            correlation_id = approval.new_correlation_id()
            self._pending[thread_id] = {
                "order_id": order_id,
                "reason": message,
                "customer_id": customer_id,
                "correlation_id": correlation_id,
            }
            text = (
                f"A refund of £{amount/100:.2f} for order #{order_id} exceeds the "
                f"£{self.settings.refund_approval_threshold_pence/100:.2f} auto-approval limit "
                f"and needs a human to sign off."
            )
            return AgentTurnResult(
                reply=text,
                events=[{
                    "type": "approval_requested",
                    "approval_id": correlation_id,
                    "amount_pence": amount,
                    "message": f"refund of £{amount/100:.2f} for order #{order_id} is pending human approval",
                }],
                requires_approval=True,
                approval_id=correlation_id,
                approval_text=text,
            )

        reply, events = actions.issue_refund(
            order_id, message, customer_id, self.session, self.enforce_ownership,
            issued_by=self.settings.agent_name,
        )
        return AgentTurnResult(reply=reply, events=events)

    def handle_resume(self, thread_id: str, approved_by: str) -> AgentTurnResult:
        self.session.begin_turn()
        pending = self._pending.pop(thread_id, None)
        if pending is None:
            return AgentTurnResult(reply="There's nothing awaiting approval.", events=[])

        events = [{
            "type": "approval_granted",
            "approval_id": pending["correlation_id"],
            "approved_by": approved_by,
            "message": f"{approved_by} approved refund for order #{pending['order_id']}",
        }]
        reply, action_events = actions.issue_refund(
            pending["order_id"],
            pending["reason"],
            pending["customer_id"],
            self.session,
            self.enforce_ownership,
            issued_by=self.settings.agent_name,
            approved_by=approved_by,
            correlation_id=pending["correlation_id"],
        )
        return AgentTurnResult(reply=reply, events=events + action_events)
