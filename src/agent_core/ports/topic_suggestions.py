"""Topic suggestion store port (topics/ARCHITECTURE.md)."""

from __future__ import annotations

from typing import Protocol
from uuid import UUID

from agent_core.domain.agents import Principal
from agent_core.domain.topic_suggestions import SuggestionState, TopicSuggestion


class TopicSuggestionStore(Protocol):
    async def add(self, suggestion: TopicSuggestion) -> bool:
        """Store a new suggestion; False when the topic already has its fingerprint."""
        ...

    async def get(self, principal: Principal, suggestion_id: UUID) -> TopicSuggestion:
        """The owner's suggestion, or NotFoundError."""
        ...

    async def list(
        self, principal: Principal, topic_id: str, state: SuggestionState | None = None
    ) -> list[TopicSuggestion]:
        """A topic's suggestions, oldest first."""
        ...

    async def decide(self, suggestion: TopicSuggestion) -> TopicSuggestion:
        """Record the owner's decision (state and decided_at)."""
        ...
