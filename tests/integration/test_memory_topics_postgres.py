"""PostgreSQL parity for topics as a relevance signal (topics/ARCHITECTURE.md)."""

from __future__ import annotations

from dataclasses import replace
from pathlib import Path
from uuid import UUID, uuid4

from agent_core.bootstrap import Composition, build
from agent_core.config import Settings
from agent_core.domain.events import NewEvent
from agent_core.domain.memory import (
    BeliefType,
    MemoryBrowseQuery,
    MemoryRecord,
    RecallQuery,
    Sensitivity,
)
from tests.integration.m2_support import database_settings


def _settings(tmp_path: Path) -> Settings:
    return replace(database_settings(), artifact_root=tmp_path / "topic-artifacts")


async def _remember(
    app: Composition, session_id: UUID, statement: str, subject: str
) -> MemoryRecord:
    async with app.uow_factory() as uow:
        event = await uow.events.append(
            NewEvent(
                session_id=session_id,
                run_id=None,
                event_type="user.message.created",
                actor_type="principal",
                actor_id=app.principal.principal_id,
                payload={"content": statement},
            )
        )
    return await app.memory.remember(
        session_id=session_id,
        run_id=None,
        statement=statement,
        subject=subject,
        scope="general",
        belief_type=BeliefType.FACT,
        portability=None,
        sensitivity=Sensitivity.INTERNAL,
        source_event_ids=[event.sequence],
    )


def _query(app: Composition, marker: str, topic_id: str | None) -> RecallQuery:
    return RecallQuery(
        tenant_id=app.principal.tenant_id,
        principal_id=app.principal.principal_id,
        current_scope="general",
        topic_id=topic_id,
        text=marker,
        budget_tokens=2_000,
        max_items=20,
        min_score=0,
    )


async def test_postgres_topics_share_recall_and_rank_the_current_topic_first(
    tmp_path: Path,
) -> None:
    marker = f"topicrank{uuid4().hex[:10]}"
    async with build(settings=_settings(tmp_path), storage="postgres") as app:
        core_session = await app.sessions.create()
        garden_session = await app.sessions.create(topic_id=f"garden-{marker}")
        household_session = await app.sessions.create(topic_id=f"household-{marker}")
        core = await _remember(
            app, core_session, f"Core {marker} prefers mornings", f"core {marker}"
        )
        garden = await _remember(
            app, garden_session, f"Garden {marker} bed three sun", f"bed {marker}"
        )
        household = await _remember(
            app, household_session, f"Household {marker} plumber Tuesday", f"plumber {marker}"
        )
        assert (core.topic_id, garden.topic_id) == (None, f"garden-{marker}")
        everything = {core.id, garden.id, household.id}
        async with app.uow_factory() as uow:
            for topic_id in (f"garden-{marker}", None):
                found = await uow.memories.query(_query(app, marker, topic_id))
                assert {record.id for record in found} == everything
            only_garden = await uow.memories.browse(
                MemoryBrowseQuery(
                    tenant_id=app.principal.tenant_id,
                    principal_id=app.principal.principal_id,
                    ceiling=Sensitivity.RESTRICTED,
                    filter_topic=True,
                    topic_id=f"garden-{marker}",
                )
            )
        assert {record.id for record in only_garden} == {garden.id}

        result = await app.memory_retriever.recall(
            _query(app, marker, None), session_id=garden_session
        )
        scores = {item.belief_id: item.score for item in result.items}
        assert household.id in scores and garden.id in scores
        assert scores[household.id] < scores[garden.id]

        again = await _remember(
            app, household_session, f"Garden {marker} bed three sun", f"bed {marker}"
        )
        assert again.id == garden.id and again.topic_id == f"garden-{marker}"


async def test_postgres_topic_suggestions_dedupe_and_decide(tmp_path: Path) -> None:
    from agent_core.domain.topic_suggestions import (
        SuggestionKind,
        SuggestionState,
        TopicSuggestion,
        suggestion_fingerprint,
    )

    topic_id = f"garden-{uuid4().hex[:10]}"
    async with build(settings=_settings(tmp_path), storage="postgres") as app:
        owner = app.principal
        now = app.clock.now()

        def made(text: str) -> TopicSuggestion:
            return TopicSuggestion(
                id=uuid4(),
                tenant_id=owner.tenant_id,
                principal_id=owner.principal_id,
                topic_id=topic_id,
                kind=SuggestionKind.INSTRUCTIONS,
                title="Units",
                rationale="Seen in chats.",
                instruction_text=text,
                fingerprint=suggestion_fingerprint(SuggestionKind.INSTRUCTIONS, text),
                state=SuggestionState.PROPOSED,
                created_at=now,
            )

        first = made("Use metric units.")
        async with app.uow_factory() as uow:
            assert await uow.topic_suggestions.add(first)
            assert not await uow.topic_suggestions.add(made("use  METRIC units."))
        async with app.uow_factory() as uow:
            await uow.topic_suggestions.decide(
                first.model_copy(update={"state": SuggestionState.DISMISSED, "decided_at": now})
            )
        async with app.uow_factory() as uow:
            assert (
                await uow.topic_suggestions.get(owner, first.id)
            ).state is SuggestionState.DISMISSED
            assert await uow.topic_suggestions.list(owner, topic_id, SuggestionState.PROPOSED) == []
