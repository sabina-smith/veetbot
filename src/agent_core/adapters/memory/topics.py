"""In-memory topic registry."""

from __future__ import annotations

from agent_core.domain.agents import Principal
from agent_core.domain.errors import NotFoundError
from agent_core.domain.topics import Topic


class InMemoryTopicStore:
    def __init__(self) -> None:
        self._topics: dict[tuple[str, str, str], Topic] = {}

    async def get(self, principal: Principal, topic_id: str) -> Topic:
        try:
            return self._topics[(principal.tenant_id, principal.principal_id, topic_id)]
        except KeyError as exc:
            raise NotFoundError("topic not found") from exc

    async def list(self, principal: Principal) -> list[Topic]:
        owner = (principal.tenant_id, principal.principal_id)
        return sorted(
            (topic for key, topic in self._topics.items() if key[:2] == owner),
            key=lambda topic: topic.id,
        )

    async def put(self, topic: Topic) -> Topic:
        self._topics[(topic.tenant_id, topic.principal_id, topic.id)] = topic
        return topic
