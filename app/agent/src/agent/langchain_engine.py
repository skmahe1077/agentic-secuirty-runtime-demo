"""The real agent: `create_agent` (LangChain 1.x, LangGraph underneath) +
Claude, wired to the same `actions.py` the deterministic engine uses.

NEEDS LIVE VALIDATION: written against documented LangChain 1.4 /
LangGraph 1.2 behaviour (see docs/RUNBOOK.md's research appendix), but this
sandbox has no ANTHROPIC_API_KEY to run it against a real model. Before
relying on this for the talk: run it once end to end, in particular the
`__interrupt__` detection in `_check_interrupt` below, which is the one
piece of LangGraph plumbing not exercised here.
"""
from __future__ import annotations

from langchain.agents import create_agent
from langchain_anthropic import ChatAnthropic
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.types import Command

from config import Settings
from engine_base import AgentTurnResult
from langchain_tools import ALL_TOOLS, AgentContext

SYSTEM_PROMPT = """You are Nimbus Store's customer support agent. You can look
up orders and issue refunds for the customer you are currently chatting
with. Only act on the order numbers the customer gives you. Be concise."""


class LangChainEngine:
    def __init__(self, settings: Settings, session):
        self.settings = settings
        self.session = session
        self.enforce_ownership = settings.agent_mode == "secure"
        self._checkpointer = InMemorySaver()
        self._model = ChatAnthropic(model=settings.anthropic_model, max_tokens=1024)
        self._agent = create_agent(
            model=self._model,
            tools=ALL_TOOLS,
            system_prompt=SYSTEM_PROMPT,
            checkpointer=self._checkpointer,
        )
        # thread_id -> AgentContext, so a resume can reuse the same shared
        # `events` list and customer/session binding as the original turn.
        self._contexts: dict[str, AgentContext] = {}

    def _config(self, thread_id: str) -> dict:
        return {"configurable": {"thread_id": thread_id}}

    def _context_for(self, customer_id: int, thread_id: str) -> AgentContext:
        ctx = self._contexts.get(thread_id)
        if ctx is None or ctx.customer_id != customer_id:
            ctx = AgentContext(
                customer_id=customer_id,
                session=self.session,
                enforce_ownership=self.enforce_ownership,
                issued_by=self.settings.agent_name,
                refund_approval_threshold_pence=self.settings.refund_approval_threshold_pence,
            )
            self._contexts[thread_id] = ctx
        return ctx

    def _check_interrupt(self, result) -> dict | None:
        """LangGraph surfaces a paused graph as an `__interrupt__` key on the
        returned state, holding a list of `Interrupt` objects whose `.value`
        is whatever was passed to `interrupt(...)`. Confirm this shape
        against a live run -- see module docstring."""
        interrupts = result.get("__interrupt__") if isinstance(result, dict) else None
        if not interrupts:
            return None
        return interrupts[0].value

    def handle_message(self, customer_id: int, message: str, thread_id: str) -> AgentTurnResult:
        ctx = self._context_for(customer_id, thread_id)
        ctx.events.clear()
        result = self._agent.invoke(
            {"messages": [{"role": "user", "content": message}]},
            config=self._config(thread_id),
            context=ctx,
        )
        pending = self._check_interrupt(result)
        if pending:
            return AgentTurnResult(
                reply=(
                    f"A refund of £{pending['amount_pence']/100:.2f} for order "
                    f"#{pending['order_id']} needs a human to approve."
                ),
                events=list(ctx.events),
                requires_approval=True,
                approval_id=pending["approval_id"],
                approval_text=f"Approve refund of £{pending['amount_pence']/100:.2f}?",
            )
        reply = result["messages"][-1].content
        return AgentTurnResult(reply=reply, events=list(ctx.events))

    def handle_resume(self, thread_id: str, approved_by: str) -> AgentTurnResult:
        ctx = self._contexts.get(thread_id)
        if ctx is None:
            return AgentTurnResult(reply="There's nothing awaiting approval.", events=[])
        ctx.events.clear()
        result = self._agent.invoke(
            Command(resume=approved_by),
            config=self._config(thread_id),
            context=ctx,
        )
        reply = result["messages"][-1].content
        return AgentTurnResult(reply=reply, events=list(ctx.events))
