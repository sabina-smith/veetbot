"""Topic walls: a topic reads its own beliefs plus core, never another topic's.

See topics/ARCHITECTURE.md. ``topic_id`` None is core.
"""

from uuid import UUID

import pytest

from agent_core.adapters.determinism import FixedClock
from agent_core.adapters.memory.in_memory import InMemoryMemoryStore
from agent_core.adapters.memory.reconsolidation_index import ReconsolidationIndex
from agent_core.adapters.memory.transactions import MemoryTransaction
from agent_core.adapters.persistence.unit_of_work import MemoryUnitOfWorkFactory
from agent_core.domain.events import NewEvent
from agent_core.domain.memory import BeliefType, MemoryRecord, Sensitivity
from agent_core.domain.reconsolidation import compatible
from agent_core.domain.topics import Topic
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


async def test_a_topic_recalls_itself_and_core_but_never_another_topic() -> None:
    store, core, garden, household = await _seeded()
    garden_view = await store.query(recall_query().model_copy(update={"topic_id": "garden"}))
    assert _ids(garden_view) == {core.id.int, garden.id.int}
    household_view = await store.query(recall_query().model_copy(update={"topic_id": "household"}))
    assert _ids(household_view) == {core.id.int, household.id.int}


async def test_core_recall_sees_only_core() -> None:
    store, core, _, _ = await _seeded()
    assert _ids(await store.query(recall_query())) == {core.id.int}


async def test_related_beliefs_for_deduplication_respect_the_wall() -> None:
    store, core, garden, _ = await _seeded()
    related = await store.related(
        TENANT, PRINCIPAL_ID, "answer style", BeliefType.PREFERENCE, topic_id="garden"
    )
    assert _ids(related) == {core.id.int, garden.id.int}
    core_related = await store.related(TENANT, PRINCIPAL_ID, "answer style", BeliefType.PREFERENCE)
    assert _ids(core_related) == {core.id.int}


async def test_a_belief_defaults_to_core() -> None:
    assert memory().topic_id is None


async def _topic_session(factory: MemoryUnitOfWorkFactory, topic_id: str, value: int) -> UUID:
    async with factory() as uow:
        core = await uow.sessions.get(SESSION_ID, principal())
        session = core.model_copy(update={"id": UUID(int=value), "topic_id": topic_id})
        await uow.sessions.create(session)
    return session.id


async def test_the_retriever_reads_the_sessions_topic_whatever_the_caller_asks() -> None:
    _clock, factory, _service, retriever = await formation_stack()
    core, garden, household = _in(None, 601, 1), _in("garden", 602, 2), _in("household", 603, 3)
    async with factory() as uow:
        for record in (core, garden, household):
            await uow.memories.upsert_belief(record)
    garden_session = await _topic_session(factory, "garden", 7001)

    forged = recall_query().model_copy(update={"topic_id": "household"})
    in_garden = await retriever.recall(forged, session_id=garden_session)
    assert {item.belief_id.int for item in in_garden.items} == {core.id.int, garden.id.int}

    in_core = await retriever.recall(
        recall_query().model_copy(update={"topic_id": "garden"}), session_id=SESSION_ID
    )
    assert {item.belief_id.int for item in in_core.items} == {core.id.int}


async def test_formation_stamps_new_beliefs_with_the_sessions_topic() -> None:
    _clock, factory, service, _retriever = await formation_stack()
    garden_session = await _topic_session(factory, "garden", 7002)
    async with factory() as uow:
        event = await uow.events.append(
            NewEvent(
                session_id=garden_session,
                run_id=None,
                event_type="user.message.created",
                actor_type="principal",
                actor_id=PRINCIPAL_ID,
                payload={"content": "Remember that bed three gets full sun"},
            )
        )
    record = await service.remember(
        session_id=garden_session,
        run_id=None,
        statement="Bed three gets full sun",
        subject="bed three",
        scope="general",
        belief_type=BeliefType.FACT,
        portability=None,
        sensitivity=Sensitivity.INTERNAL,
        source_event_ids=[event.sequence],
    )
    assert record.topic_id == "garden"


async def test_list_memories_is_owner_wide_unless_walled_to_a_topic() -> None:
    store, core, garden, household = await _seeded()
    assert _ids(await store.list_memories(principal())) == {
        core.id.int,
        garden.id.int,
        household.id.int,
    }
    walled = await store.list_memories(principal(), topic_wall=True, topic_id="garden")
    assert _ids(walled) == {core.id.int, garden.id.int}
    core_only = await store.list_memories(principal(), topic_wall=True)
    assert _ids(core_only) == {core.id.int}


def test_reconsolidation_never_groups_beliefs_across_topics() -> None:
    garden, household, core = _in("garden", 611, 1), _in("household", 612, 2), _in(None, 613, 3)
    assert compatible(garden, garden.model_copy(update={"id": UUID(int=614)}))
    assert not compatible(garden, household)
    assert not compatible(garden, core)


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


async def _register(factory: MemoryUnitOfWorkFactory, topic_id: str, *, sealed: bool) -> None:
    owner = principal()
    async with factory() as uow:
        await uow.topics.put(
            Topic(
                id=topic_id,
                tenant_id=owner.tenant_id,
                principal_id=owner.principal_id,
                name=topic_id,
                sealed=sealed,
                created_at=NOW,
                updated_at=NOW,
            )
        )


async def _learn(
    factory: MemoryUnitOfWorkFactory, service: GovernedMemoryService, session_id: UUID
) -> MemoryRecord:
    statement = "User is allergic to bee stings"
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


async def test_the_same_fact_learned_in_two_topics_is_promoted_to_core() -> None:
    _clock, factory, service, _retriever = await formation_stack()
    await _register(factory, "garden", sealed=False)
    await _register(factory, "household", sealed=False)
    first = await _learn(factory, service, await _topic_session(factory, "garden", 7101))
    assert first.topic_id == "garden"
    second = await _learn(factory, service, await _topic_session(factory, "household", 7102))
    assert second.id == first.id
    assert second.topic_id is None
    async with factory() as uow:
        live = await uow.memories.list_memories(principal())
    assert [record.id for record in live] == [first.id]


@pytest.mark.parametrize("sealed_side", ["first", "second"])
async def test_a_sealed_topic_never_promotes_or_is_promoted(sealed_side: str) -> None:
    _clock, factory, service, _retriever = await formation_stack()
    await _register(factory, "health", sealed=True)
    await _register(factory, "garden", sealed=False)
    order = ["health", "garden"] if sealed_side == "first" else ["garden", "health"]
    first = await _learn(factory, service, await _topic_session(factory, order[0], 7201))
    second = await _learn(factory, service, await _topic_session(factory, order[1], 7202))
    assert second.id != first.id
    assert {first.topic_id, second.topic_id} == {"health", "garden"}


async def test_an_unregistered_topic_never_promotes() -> None:
    _clock, factory, service, _retriever = await formation_stack()
    await _register(factory, "garden", sealed=False)
    first = await _learn(factory, service, await _topic_session(factory, "garden", 7301))
    second = await _learn(factory, service, await _topic_session(factory, "mystery", 7302))
    assert second.id != first.id and second.topic_id == "mystery"
