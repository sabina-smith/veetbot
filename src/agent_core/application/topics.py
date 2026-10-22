"""Public topic registry service (topics/ARCHITECTURE.md)."""

from __future__ import annotations

import builtins
from uuid import UUID

from agent_core.application.authorization import require_scope
from agent_core.domain.agents import Principal
from agent_core.domain.errors import ConflictError, NotFoundError
from agent_core.domain.topic_suggestions import (
    SuggestionKind,
    SuggestionState,
    TopicReviewInput,
    TopicSuggestion,
    TopicSuggestionView,
    suggestion_fingerprint,
)
from agent_core.domain.topics import Topic, TopicCreateRequest, TopicUpdateRequest, TopicView
from agent_core.ports.determinism import Clock, IdFactory
from agent_core.ports.persistence import RepositoryUnitOfWork, UnitOfWorkFactory
from agent_core.ports.topic_review import TopicReviewer

# A review looks at this much recent use and proposes at most this many changes.
REVIEW_SESSIONS = 20
REVIEW_MESSAGES = 40
REVIEW_MESSAGE_CHARACTERS = 500
REVIEW_MAX_SUGGESTIONS = 3


def _content(suggestion: TopicSuggestion) -> str:
    if suggestion.instruction_text is not None:
        return suggestion.instruction_text
    return "" if suggestion.schedule is None else suggestion.schedule.title


async def _recent_user_messages(
    uow: RepositoryUnitOfWork, principal: Principal, topic_id: str
) -> builtins.list[str]:
    sessions = [
        session
        for session in await uow.sessions.list(principal, limit=200)
        if session.topic_id == topic_id
    ][:REVIEW_SESSIONS]
    messages: builtins.list[str] = []
    for session in sessions:
        for event in await uow.events.list_after(session.id, 0, principal):
            content = event.payload.get("content")
            if (
                event.event_type == "user.message.created"
                and event.actor_type == "principal"
                and isinstance(content, str)
                and content.strip()
            ):
                messages.append(content.strip()[:REVIEW_MESSAGE_CHARACTERS])
    return messages[-REVIEW_MESSAGES:]


class PublicTopicService:
    def __init__(
        self,
        *,
        uow_factory: UnitOfWorkFactory,
        clock: Clock,
        ids: IdFactory | None = None,
        reviewer: TopicReviewer | None = None,
    ) -> None:
        self._uow_factory = uow_factory
        self._clock = clock
        self._ids = ids
        self._reviewer = reviewer

    async def review(
        self, principal: Principal, topic_id: str
    ) -> builtins.list[TopicSuggestionView]:
        """Ask the topic's agent what to change, from how the owner used the topic.

        The model call runs outside any transaction; only new suggestions are
        stored, so a duplicate or a previously dismissed one never reappears.
        """
        require_scope(principal, "session.write")
        if self._reviewer is None or self._ids is None:
            return []
        async with self._uow_factory() as uow:
            topic = await uow.topics.get(principal, topic_id)
            messages = await _recent_user_messages(uow, principal, topic_id)
            decided = await uow.topic_suggestions.list(principal, topic_id)
        if not messages:
            return []
        answer = await self._reviewer.review(
            TopicReviewInput(
                topic_name=topic.name,
                instructions=topic.instructions,
                recent_user_messages=messages,
                accepted=[
                    _content(item) for item in decided if item.state is SuggestionState.ACCEPTED
                ],
                dismissed=[
                    _content(item) for item in decided if item.state is SuggestionState.DISMISSED
                ],
            ),
            principal=principal,
        )
        made: builtins.list[TopicSuggestionView] = []
        async with self._uow_factory() as uow:
            for proposed in answer.suggestions[:REVIEW_MAX_SUGGESTIONS]:
                content = proposed.instruction_text or (
                    proposed.schedule.model_dump_json() if proposed.schedule else ""
                )
                try:
                    suggestion = TopicSuggestion(
                        id=self._ids.new_id(),
                        tenant_id=principal.tenant_id,
                        principal_id=principal.principal_id,
                        topic_id=topic_id,
                        kind=proposed.kind,
                        title=proposed.title,
                        rationale=proposed.rationale,
                        instruction_text=proposed.instruction_text,
                        schedule=proposed.schedule,
                        fingerprint=suggestion_fingerprint(proposed.kind, content),
                        state=SuggestionState.PROPOSED,
                        created_at=self._clock.now(),
                    )
                except ValueError:
                    continue  # a malformed proposal is dropped, never repaired
                if await uow.topic_suggestions.add(suggestion):
                    made.append(TopicSuggestionView.from_suggestion(suggestion))
        return made

    async def list(self, principal: Principal) -> list[TopicView]:
        require_scope(principal, "session.read")
        async with self._uow_factory() as uow:
            return [TopicView.from_topic(topic) for topic in await uow.topics.list(principal)]

    async def create(self, principal: Principal, request: TopicCreateRequest) -> TopicView:
        require_scope(principal, "session.write")
        now = self._clock.now()
        async with self._uow_factory() as uow:
            try:
                await uow.topics.get(principal, request.id)
            except NotFoundError:
                pass
            else:
                raise ConflictError("topic already exists")
            topic = Topic(
                id=request.id,
                tenant_id=principal.tenant_id,
                principal_id=principal.principal_id,
                name=request.name,
                instructions=request.instructions,
                sealed=request.sealed,
                created_at=now,
                updated_at=now,
            )
            return TopicView.from_topic(await uow.topics.put(topic))

    async def update(
        self, principal: Principal, topic_id: str, request: TopicUpdateRequest
    ) -> TopicView:
        require_scope(principal, "session.write")
        async with self._uow_factory() as uow:
            current = await uow.topics.get(principal, topic_id)
            changes: dict[str, object] = {"updated_at": self._clock.now()}
            if request.name is not None:
                changes["name"] = request.name
            if request.instructions is not None:
                changes["instructions"] = request.instructions
            if request.sealed is not None:
                changes["sealed"] = request.sealed
            return TopicView.from_topic(await uow.topics.put(current.model_copy(update=changes)))

    async def list_suggestions(
        self, principal: Principal, topic_id: str
    ) -> builtins.list[TopicSuggestionView]:
        require_scope(principal, "session.read")
        async with self._uow_factory() as uow:
            await uow.topics.get(principal, topic_id)
            return [
                TopicSuggestionView.from_suggestion(item)
                for item in await uow.topic_suggestions.list(
                    principal, topic_id, SuggestionState.PROPOSED
                )
            ]

    async def accept_suggestion(
        self, principal: Principal, topic_id: str, suggestion_id: UUID
    ) -> TopicSuggestionView:
        require_scope(principal, "session.write")
        async with self._uow_factory() as uow:
            suggestion = await self._open(uow, principal, topic_id, suggestion_id)
            if suggestion.kind is SuggestionKind.INSTRUCTIONS:
                topic = await uow.topics.get(principal, topic_id)
                text = suggestion.instruction_text or ""
                instructions = text if not topic.instructions else f"{topic.instructions}\n{text}"
                await uow.topics.put(
                    topic.model_copy(
                        update={"instructions": instructions, "updated_at": self._clock.now()}
                    )
                )
            else:
                raise ConflictError("schedule suggestions cannot be accepted yet")
            decided = await uow.topic_suggestions.decide(
                suggestion.model_copy(
                    update={"state": SuggestionState.ACCEPTED, "decided_at": self._clock.now()}
                )
            )
            return TopicSuggestionView.from_suggestion(decided)

    async def dismiss_suggestion(
        self, principal: Principal, topic_id: str, suggestion_id: UUID
    ) -> TopicSuggestionView:
        require_scope(principal, "session.write")
        async with self._uow_factory() as uow:
            suggestion = await self._open(uow, principal, topic_id, suggestion_id)
            decided = await uow.topic_suggestions.decide(
                suggestion.model_copy(
                    update={"state": SuggestionState.DISMISSED, "decided_at": self._clock.now()}
                )
            )
            return TopicSuggestionView.from_suggestion(decided)

    @staticmethod
    async def _open(
        uow: RepositoryUnitOfWork, principal: Principal, topic_id: str, suggestion_id: UUID
    ) -> TopicSuggestion:
        suggestion = await uow.topic_suggestions.get(principal, suggestion_id)
        if suggestion.topic_id != topic_id:
            raise NotFoundError("suggestion not found")
        if suggestion.state is not SuggestionState.PROPOSED:
            raise ConflictError("suggestion was already decided")
        return suggestion
