"""Topic registry contract (topics/ARCHITECTURE.md)."""

import pytest
from pydantic import ValidationError

from agent_core.adapters.memory.topics import InMemoryTopicStore
from agent_core.domain.errors import NotFoundError
from agent_core.domain.topics import Topic
from tests.contract.support import NOW, principal


def _topic(topic_id: str = "garden", *, sealed: bool = False) -> Topic:
    owner = principal()
    return Topic(
        id=topic_id,
        tenant_id=owner.tenant_id,
        principal_id=owner.principal_id,
        name=topic_id.title(),
        sealed=sealed,
        created_at=NOW,
        updated_at=NOW,
    )


async def test_topics_are_owner_scoped_and_upserted() -> None:
    store = InMemoryTopicStore()
    await store.put(_topic("garden"))
    await store.put(_topic("health", sealed=True))
    await store.put(_topic("garden").model_copy(update={"name": "Garden & yard"}))
    assert [topic.id for topic in await store.list(principal())] == ["garden", "health"]
    assert (await store.get(principal(), "garden")).name == "Garden & yard"
    assert (await store.get(principal(), "health")).sealed is True
    stranger = principal().model_copy(update={"principal_id": "someone-else"})
    assert await store.list(stranger) == []
    with pytest.raises(NotFoundError):
        await store.get(stranger, "garden")


@pytest.mark.parametrize("bad", ["core", "Garden", "has space", "", "-lead", "x" * 65])
def test_topic_ids_are_lowercase_slugs_and_core_is_reserved(bad: str) -> None:
    with pytest.raises(ValidationError):
        _topic(bad)
