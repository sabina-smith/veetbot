"""PostgreSQL topic suggestion store (topics/ARCHITECTURE.md)."""

from __future__ import annotations

from typing import Any
from uuid import UUID

from sqlalchemy import select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from agent_core.adapters.persistence.sqlalchemy_models import TopicSuggestionRow
from agent_core.domain.agents import Principal
from agent_core.domain.errors import NotFoundError
from agent_core.domain.topic_suggestions import (
    ScheduleDraft,
    SuggestionKind,
    SuggestionState,
    TopicSuggestion,
)


def _suggestion(row: TopicSuggestionRow) -> TopicSuggestion:
    return TopicSuggestion(
        id=row.id,
        tenant_id=row.tenant_id,
        principal_id=row.principal_id,
        topic_id=row.topic_id,
        kind=SuggestionKind(row.kind),
        title=row.title,
        rationale=row.rationale,
        instruction_text=row.instruction_text,
        schedule=None if row.schedule is None else ScheduleDraft.model_validate(row.schedule),
        fingerprint=row.fingerprint,
        state=SuggestionState(row.state),
        created_at=row.created_at,
        decided_at=row.decided_at,
    )


def _values(suggestion: TopicSuggestion) -> dict[str, Any]:
    values = suggestion.model_dump(mode="python", exclude={"schedule"})
    values["kind"] = suggestion.kind.value
    values["state"] = suggestion.state.value
    values["schedule"] = (
        None if suggestion.schedule is None else suggestion.schedule.model_dump(mode="json")
    )
    return values


class PostgresTopicSuggestionStore:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def add(self, suggestion: TopicSuggestion) -> bool:
        result = await self._session.execute(
            pg_insert(TopicSuggestionRow)
            .values(**_values(suggestion))
            .on_conflict_do_nothing(constraint="uq_topic_suggestions_fingerprint")
        )
        return bool(getattr(result, "rowcount", 0))

    async def get(self, principal: Principal, suggestion_id: UUID) -> TopicSuggestion:
        row = await self._session.scalar(
            select(TopicSuggestionRow).where(
                TopicSuggestionRow.id == suggestion_id,
                TopicSuggestionRow.tenant_id == principal.tenant_id,
                TopicSuggestionRow.principal_id == principal.principal_id,
            )
        )
        if row is None:
            raise NotFoundError("suggestion not found")
        return _suggestion(row)

    async def list(
        self, principal: Principal, topic_id: str, state: SuggestionState | None = None
    ) -> list[TopicSuggestion]:
        statement = select(TopicSuggestionRow).where(
            TopicSuggestionRow.tenant_id == principal.tenant_id,
            TopicSuggestionRow.principal_id == principal.principal_id,
            TopicSuggestionRow.topic_id == topic_id,
        )
        if state is not None:
            statement = statement.where(TopicSuggestionRow.state == state.value)
        rows = await self._session.scalars(
            statement.order_by(TopicSuggestionRow.created_at, TopicSuggestionRow.id)
        )
        return [_suggestion(row) for row in rows.all()]

    async def decide(self, suggestion: TopicSuggestion) -> TopicSuggestion:
        result = await self._session.execute(
            update(TopicSuggestionRow)
            .where(
                TopicSuggestionRow.id == suggestion.id,
                TopicSuggestionRow.tenant_id == suggestion.tenant_id,
                TopicSuggestionRow.principal_id == suggestion.principal_id,
            )
            .values(state=suggestion.state.value, decided_at=suggestion.decided_at)
        )
        if not getattr(result, "rowcount", 0):
            raise NotFoundError("suggestion not found")
        return suggestion
