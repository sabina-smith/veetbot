"""Public topic registry service (topics/ARCHITECTURE.md)."""

from __future__ import annotations

from agent_core.application.authorization import require_scope
from agent_core.domain.agents import Principal
from agent_core.domain.errors import ConflictError, NotFoundError
from agent_core.domain.topics import Topic, TopicCreateRequest, TopicUpdateRequest, TopicView
from agent_core.ports.determinism import Clock
from agent_core.ports.persistence import UnitOfWorkFactory


class PublicTopicService:
    def __init__(self, *, uow_factory: UnitOfWorkFactory, clock: Clock) -> None:
        self._uow_factory = uow_factory
        self._clock = clock

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
            if request.sealed is not None:
                changes["sealed"] = request.sealed
            return TopicView.from_topic(await uow.topics.put(current.model_copy(update=changes)))
