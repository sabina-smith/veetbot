"""In-memory topic suggestion store."""

from __future__ import annotations

from uuid import UUID

from agent_core.domain.agents import Principal
from agent_core.domain.errors import NotFoundError
from agent_core.domain.topic_suggestions import SuggestionState, TopicSuggestion


class InMemoryTopicSuggestionStore:
    def __init__(self) -> None:
        self._suggestions: dict[UUID, TopicSuggestion] = {}

    async def add(self, suggestion: TopicSuggestion) -> bool:
        key = (suggestion.tenant_id, suggestion.principal_id, suggestion.topic_id)
        if any(
            (item.tenant_id, item.principal_id, item.topic_id) == key
            and item.fingerprint == suggestion.fingerprint
            for item in self._suggestions.values()
        ):
            return False
        self._suggestions[suggestion.id] = suggestion
        return True

    async def get(self, principal: Principal, suggestion_id: UUID) -> TopicSuggestion:
        found = self._suggestions.get(suggestion_id)
        if found is None or (found.tenant_id, found.principal_id) != (
            principal.tenant_id,
            principal.principal_id,
        ):
            raise NotFoundError("suggestion not found")
        return found

    async def list(
        self, principal: Principal, topic_id: str, state: SuggestionState | None = None
    ) -> list[TopicSuggestion]:
        return sorted(
            (
                item
                for item in self._suggestions.values()
                if (item.tenant_id, item.principal_id, item.topic_id)
                == (principal.tenant_id, principal.principal_id, topic_id)
                and (state is None or item.state is state)
            ),
            key=lambda item: (item.created_at, str(item.id)),
        )

    async def decide(self, suggestion: TopicSuggestion) -> TopicSuggestion:
        if suggestion.id not in self._suggestions:
            raise NotFoundError("suggestion not found")
        self._suggestions[suggestion.id] = suggestion
        return suggestion
