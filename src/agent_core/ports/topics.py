"""Topic registry port (topics/ARCHITECTURE.md)."""

from __future__ import annotations

from typing import Protocol

from agent_core.domain.agents import Principal
from agent_core.domain.topics import Topic


class TopicStore(Protocol):
    async def get(self, principal: Principal, topic_id: str) -> Topic:
        """The owner's topic, or NotFoundError."""
        ...

    async def list(self, principal: Principal) -> list[Topic]:
        """The owner's topics, ordered by id."""
        ...

    async def put(self, topic: Topic) -> Topic:
        """Create or replace the owner's topic with this id."""
        ...
