"""PostgreSQL topic registry (topics/ARCHITECTURE.md)."""

from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from agent_core.adapters.persistence.sqlalchemy_models import TopicRow
from agent_core.domain.agents import Principal
from agent_core.domain.errors import NotFoundError
from agent_core.domain.topics import Topic


def _topic(row: TopicRow) -> Topic:
    return Topic(
        id=row.id,
        tenant_id=row.tenant_id,
        principal_id=row.principal_id,
        name=row.name,
        instructions=row.instructions,
        sealed=row.sealed,
        created_at=row.created_at,
        updated_at=row.updated_at,
    )


class PostgresTopicStore:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def get(self, principal: Principal, topic_id: str) -> Topic:
        row = await self._session.get(
            TopicRow, (principal.tenant_id, principal.principal_id, topic_id)
        )
        if row is None:
            raise NotFoundError("topic not found")
        return _topic(row)

    async def list(self, principal: Principal) -> list[Topic]:
        rows = await self._session.scalars(
            select(TopicRow)
            .where(
                TopicRow.tenant_id == principal.tenant_id,
                TopicRow.principal_id == principal.principal_id,
            )
            .order_by(TopicRow.id)
        )
        return [_topic(row) for row in rows.all()]

    async def put(self, topic: Topic) -> Topic:
        values = topic.model_dump()
        await self._session.execute(
            pg_insert(TopicRow)
            .values(**values)
            .on_conflict_do_update(
                index_elements=["tenant_id", "principal_id", "id"],
                set_={key: values[key] for key in ("name", "instructions", "sealed", "updated_at")},
            )
        )
        return topic
