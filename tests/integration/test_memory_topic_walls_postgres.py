"""PostgreSQL parity for topic walls (topics/ARCHITECTURE.md)."""

from __future__ import annotations

from dataclasses import replace
from pathlib import Path
from uuid import UUID, uuid4

from agent_core.bootstrap import Composition, build
from agent_core.config import Settings
from agent_core.domain.events import NewEvent
from agent_core.domain.memory import BeliefType, MemoryRecord, RecallQuery, Sensitivity
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


async def test_postgres_topic_wall_matches_the_contract(tmp_path: Path) -> None:
    marker = f"topicwall{uuid4().hex[:10]}"
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

        async with app.uow_factory() as uow:
            in_garden = await uow.memories.query(_query(app, marker, f"garden-{marker}"))
            in_core = await uow.memories.query(_query(app, marker, None))
            related = await uow.memories.related(
                app.principal.tenant_id,
                app.principal.principal_id,
                f"plumber {marker}",
                BeliefType.FACT,
                topic_id=f"garden-{marker}",
            )
        assert {record.id for record in in_garden} == {core.id, garden.id}
        assert {record.id for record in in_core} == {core.id}
        assert related == []
        assert household.id not in {record.id for record in in_garden}

        forged = _query(app, marker, f"household-{marker}")
        result = await app.memory_retriever.recall(forged, session_id=garden_session)
        assert {item.belief_id for item in result.items} <= {core.id, garden.id}
        assert household.id not in {item.belief_id for item in result.items}


async def test_postgres_topics_registry_and_cross_topic_promotion(tmp_path: Path) -> None:
    from agent_core.domain.topics import Topic

    marker = uuid4().hex[:10]
    async with build(settings=_settings(tmp_path), storage="postgres") as app:
        owner = app.principal
        now = app.clock.now()
        topic_ids = {name: f"{name}-{marker}" for name in ("garden", "household", "health")}
        async with app.uow_factory() as uow:
            for name, topic_id in topic_ids.items():
                await uow.topics.put(
                    Topic(
                        id=topic_id,
                        tenant_id=owner.tenant_id,
                        principal_id=owner.principal_id,
                        name=name,
                        sealed=name == "health",
                        created_at=now,
                        updated_at=now,
                    )
                )
        async with app.uow_factory() as uow:
            listed = {topic.id: topic.sealed for topic in await uow.topics.list(owner)}
        assert {topic_ids[name]: name == "health" for name in topic_ids}.items() <= listed.items()

        statement, subject = f"User {marker} is allergic to bees", f"bee allergy {marker}"
        sessions = {
            name: await app.sessions.create(topic_id=topic_id)
            for name, topic_id in topic_ids.items()
        }
        sealed = await _remember(app, sessions["health"], statement, subject)
        first = await _remember(app, sessions["garden"], statement, subject)
        promoted = await _remember(app, sessions["household"], statement, subject)
        assert promoted.id == first.id and promoted.topic_id is None
        assert sealed.id != first.id and sealed.topic_id == topic_ids["health"]
