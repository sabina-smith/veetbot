"""Topics are a relevance signal, not a wall (topics/ARCHITECTURE.md, 2026-10-21).

Every topic can recall every belief; a belief's ``topic_id`` records where it
was learned (None is core) and lets the current topic's beliefs rank first.
"""

from uuid import UUID

from agent_core.adapters.determinism import FixedClock
from agent_core.adapters.memory.in_memory import InMemoryMemoryStore
from agent_core.adapters.memory.reconsolidation_index import ReconsolidationIndex
from agent_core.adapters.memory.transactions import MemoryTransaction
from agent_core.adapters.persistence.unit_of_work import MemoryUnitOfWorkFactory
from agent_core.domain.events import NewEvent
from agent_core.domain.memory import BeliefType, MemoryRecord, Sensitivity
from agent_core.domain.reconsolidation import compatible
from agent_core.memory.formation import GovernedMemoryService
from tests.contract.memory_fixtures import browse_query, formation_stack, memory, recall_query
from tests.contract.support import NOW, PRINCIPAL_ID, SESSION_ID, TENANT, principal


def _store() -> InMemoryMemoryStore:
    return InMemoryMemoryStore(FixedClock(NOW), ReconsolidationIndex(MemoryTransaction()))


def _in(topic_id: str | None, belief_id: int, position: int) -> MemoryRecord:
    return memory(
        belief_id=belief_id, statement=f"User prefers concise answers {belief_id}"
    ).model_copy(update={"topic_id": topic_id, "store_position": position})


async def _seeded() -> tuple[InMemoryMemoryStore, MemoryRecord, MemoryRecord, MemoryRecord]:
    store = _store()
    core, garden, household = _in(None, 601, 1), _in("garden", 602, 2), _in("household", 603, 3)
    for record in (core, garden, household):
        await store.upsert_belief(record)
    return store, core, garden, household


def _ids(records: list[MemoryRecord]) -> set[int]:
    return {record.id.int for record in records}


async def _topic_session(factory: MemoryUnitOfWorkFactory, topic_id: str, value: int) -> UUID:
    async with factory() as uow:
        core = await uow.sessions.get(SESSION_ID, principal())
        session = core.model_copy(update={"id": UUID(int=value), "topic_id": topic_id})
        await uow.sessions.create(session)
    return session.id


async def _learn(
    factory: MemoryUnitOfWorkFactory,
    service: GovernedMemoryService,
    session_id: UUID,
    statement: str = "User is allergic to bee stings",
) -> MemoryRecord:
    async with factory() as uow:
        event = await uow.events.append(
            NewEvent(
                session_id=session_id,
                run_id=None,
                event_type="user.message.created",
                actor_type="principal",
                actor_id=PRINCIPAL_ID,
                payload={"content": f"Remember: {statement}"},
            )
        )
    return await service.remember(
        session_id=session_id,
        run_id=None,
        statement=statement,
        subject="bee sting allergy",
        scope="general",
        belief_type=BeliefType.FACT,
        portability=None,
        sensitivity=Sensitivity.INTERNAL,
        source_event_ids=[event.sequence],
    )


def test_a_belief_defaults_to_core() -> None:
    assert memory().topic_id is None


async def test_every_topic_and_core_can_recall_every_belief() -> None:
    store, core, garden, household = await _seeded()
    everything = {core.id.int, garden.id.int, household.id.int}
    for topic_id in ("garden", "household", None):
        found = await store.query(recall_query().model_copy(update={"topic_id": topic_id}))
        assert _ids(found) == everything


async def test_the_current_topics_beliefs_rank_above_another_topics() -> None:
    _clock, factory, _service, retriever = await formation_stack()
    _, core, garden, household = await _seeded()
    async with factory() as uow:
        for record in (core, garden, household):
            await uow.memories.upsert_belief(record)
    garden_session = await _topic_session(factory, "garden", 7001)
    result = await retriever.recall(recall_query(), session_id=garden_session)
    order = [item.belief_id.int for item in result.items]
    assert set(order) == {core.id.int, garden.id.int, household.id.int}
    assert order.index(garden.id.int) < order.index(household.id.int)
    scores = {item.belief_id.int: item.score for item in result.items}
    assert scores[household.id.int] < min(scores[garden.id.int], scores[core.id.int])


async def test_formation_stamps_new_beliefs_with_the_sessions_topic() -> None:
    _clock, factory, service, _retriever = await formation_stack()
    record = await _learn(factory, service, await _topic_session(factory, "garden", 7002))
    assert record.topic_id == "garden"


async def test_the_same_fact_from_another_topic_reinforces_instead_of_duplicating() -> None:
    _clock, factory, service, _retriever = await formation_stack()
    first = await _learn(factory, service, await _topic_session(factory, "garden", 7101))
    second = await _learn(factory, service, await _topic_session(factory, "household", 7102))
    assert second.id == first.id
    assert second.topic_id == "garden"
    async with factory() as uow:
        assert [record.id for record in await uow.memories.list_memories(principal())] == [first.id]


async def test_related_beliefs_span_every_topic() -> None:
    store, core, garden, household = await _seeded()
    related = await store.related(TENANT, PRINCIPAL_ID, "answer style", BeliefType.PREFERENCE)
    assert _ids(related) == {core.id.int, garden.id.int, household.id.int}


async def test_the_owner_browses_everything_or_exactly_one_topic() -> None:
    store, core, garden, household = await _seeded()
    everything = await store.browse(browse_query())
    assert _ids(everything) == {core.id.int, garden.id.int, household.id.int}
    only_garden = await store.browse(
        browse_query().model_copy(update={"filter_topic": True, "topic_id": "garden"})
    )
    assert _ids(only_garden) == {garden.id.int}
    only_core = await store.browse(browse_query().model_copy(update={"filter_topic": True}))
    assert _ids(only_core) == {core.id.int}


def test_reconsolidation_groups_beliefs_across_topics() -> None:
    garden, household = _in("garden", 611, 1), _in("household", 612, 2)
    assert compatible(garden, household)
