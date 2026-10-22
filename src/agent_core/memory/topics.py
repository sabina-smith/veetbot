"""Topic walls (topics/ARCHITECTURE.md): resolve the topic a memory read runs inside."""

from __future__ import annotations

from collections.abc import Sequence
from uuid import UUID

from agent_core.domain.agents import Principal
from agent_core.domain.errors import NotFoundError
from agent_core.domain.events import EventEnvelope
from agent_core.ports.persistence import RepositoryUnitOfWork
from agent_core.ports.repositories import SessionRepository


async def session_topic(
    uow: RepositoryUnitOfWork, session_id: UUID, principal: Principal
) -> str | None:
    """The session's topic; a missing session (evaluations, synthetic reads) is core.

    Some recall paths run on a read-only store bundle without sessions; the topic
    only orders results, so those recall without one.
    """
    sessions: SessionRepository | None = getattr(uow, "sessions", None)
    if sessions is None:
        return None
    try:
        return (await sessions.get(session_id, principal)).topic_id
    except NotFoundError:
        return None


async def events_topic(
    uow: RepositoryUnitOfWork, events: Sequence[EventEnvelope], principal: Principal
) -> str | None:
    """The topic of the session a batch of events came from; no events is core."""
    return None if not events else await session_topic(uow, events[0].session_id, principal)
