"""Shared result type and interface for the two interchangeable engines.

`DeterministicEngine` (regex intent parsing) and `LangChainEngine`
(`create_agent` + Claude) both implement this so `server.py` doesn't care
which one is running. Swapping is one env var (`AGENT_ENGINE`), not a
rewrite -- which matters here because this sandbox has no ANTHROPIC_API_KEY
to exercise the LangChain path against, so the deterministic engine is what
actually gets tested end to end; the LangChain engine is written to the same
contract and the same action functions, ready to flip on for the real talk.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol


@dataclass
class AgentTurnResult:
    reply: str
    events: list[dict] = field(default_factory=list)
    requires_approval: bool = False
    approval_id: str | None = None
    approval_text: str | None = None


class Engine(Protocol):
    def handle_message(self, customer_id: int, message: str, thread_id: str) -> AgentTurnResult: ...

    def handle_resume(self, thread_id: str, approved_by: str) -> AgentTurnResult: ...
