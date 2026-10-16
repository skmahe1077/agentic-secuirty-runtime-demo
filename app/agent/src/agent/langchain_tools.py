"""LangChain `@tool` wrappers around `actions.py`.

Per-invocation context (which customer is chatting, whether to enforce
order ownership, the credential session, who issued the action) comes in
via a `ToolRuntime`-annotated parameter -- auto-injected by `create_agent`'s
`ToolNode` and hidden from the model's own tool schema, so the model never
sees or guesses at `customer_id`/`session`. Supplied through
`context_schema=` / `context=` on the agent in `langchain_engine.py`.
"""
from __future__ import annotations

from dataclasses import dataclass

from langchain.tools import ToolRuntime, tool
from langgraph.types import interrupt

import actions
import approval


@dataclass
class AgentContext:
    customer_id: int
    session: object
    enforce_ownership: bool
    issued_by: str
    refund_approval_threshold_pence: int
    # Tools can't return structured data to the panel (their return value is
    # a ToolMessage for the model) -- they append into this shared list
    # instead, and `langchain_engine.py` drains it after each invoke.
    events: list = None

    def __post_init__(self):
        if self.events is None:
            self.events = []


@tool
def lookup_order_tool(order_id: int, runtime: ToolRuntime) -> str:
    """Look up an order's product, total, and status by order id."""
    ctx: AgentContext = runtime.context
    reply, events = actions.lookup_order(order_id, ctx.customer_id, ctx.session, ctx.enforce_ownership)
    ctx.events.extend(events)
    return reply


@tool
def issue_refund_tool(order_id: int, reason: str, runtime: ToolRuntime) -> str:
    """Refund an order. Refunds over the auto-approval threshold pause for a
    human to approve before anything is charged back."""
    ctx: AgentContext = runtime.context

    amount = actions.peek_order_total_pence(order_id, ctx.session)
    if amount is None:
        return f"I can't find order #{order_id}."

    approved_by = None
    correlation_id = None
    if amount > ctx.refund_approval_threshold_pence:
        correlation_id = approval.new_correlation_id()
        # Conditional, data-dependent human-in-the-loop: interrupt() pauses
        # the graph only for refunds over the threshold, which a blanket
        # HumanInTheLoopMiddleware(interrupt_on={"issue_refund_tool": True})
        # cannot do -- that gates every call to this tool regardless of
        # amount. Resuming happens via Command(resume=approved_by) in
        # langchain_engine.py.
        #
        # NEEDS LIVE VALIDATION: this assumes `interrupt()` imported from
        # `langgraph.types` can be called from inside a tool body under
        # `create_agent`'s default ToolNode, and that the resume value comes
        # back as this call's return value. Confirmed only against docs,
        # not a running model -- verify against a real create_agent run
        # before relying on it on stage.
        approved_by = interrupt({
            "reason": "refund_requires_approval",
            "order_id": order_id,
            "amount_pence": amount,
            "approval_id": correlation_id,
        })

    if correlation_id:
        ctx.events.append({
            "type": "approval_granted" if approved_by else "approval_requested",
            "approval_id": correlation_id,
            "approved_by": approved_by,
            "amount_pence": amount,
            "message": f"refund of £{amount/100:.2f} for order #{order_id} approved by {approved_by}",
        })
    reply, events = actions.issue_refund(
        order_id, reason, ctx.customer_id, ctx.session, ctx.enforce_ownership,
        issued_by=ctx.issued_by, approved_by=approved_by, correlation_id=correlation_id,
    )
    ctx.events.extend(events)
    return reply


@tool
def lookup_customer_pii_tool(customer_id: int, runtime: ToolRuntime) -> str:
    """Look up a customer's contact details (name, email, phone)."""
    ctx: AgentContext = runtime.context
    reply, events = actions.lookup_customer_pii(customer_id, ctx.session, ctx.issued_by)
    ctx.events.extend(events)
    return reply


ALL_TOOLS = [lookup_order_tool, issue_refund_tool, lookup_customer_pii_tool]
