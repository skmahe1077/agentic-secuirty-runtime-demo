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
_ORDER_RE = re.compile(r"(?:order|status|look ?up|where is|find).*?#?\s*(\d{3,6})", re.IGNORECASE)
_CUSTOMER_RE = re.compile(r"customer\s*#?\s*(\d{1,6})", re.IGNORECASE)
_PII_HINT_RE = re.compile(r"phone|email|contact|address|pii", re.IGNORECASE)


class DeterministicEngine:
    def __init__(self, settings: Settings, session):
        self.settings = settings
        self.session = session
        self.enforce_ownership = settings.agent_mode == "secure"
        self._pending: dict[str, dict] = {}

    def handle_message(self, customer_id: int, message: str, thread_id: str) -> AgentTurnResult:
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

        return AgentTurnResult(
            reply="I can look up an order (\"status of order #1042\") or process a refund (\"refund order #1042\").",
            events=[],
        )

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
