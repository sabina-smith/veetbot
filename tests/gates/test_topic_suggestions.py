"""Topic suggestions: proposed by a topic's agent, decided by the owner (topics/ARCHITECTURE.md)."""

from __future__ import annotations

from datetime import time
from uuid import UUID

import httpx

from agent_core.api import create_app
from agent_core.application.topics import PublicTopicService
from agent_core.bootstrap import build
from agent_core.domain.agents import Principal
from agent_core.domain.events import NewEvent
from agent_core.domain.schedules import WeeklyCadence
from agent_core.domain.topic_suggestions import (
    ReviewedSuggestion,
    ScheduleDraft,
    SuggestionKind,
    SuggestionState,
    TopicReviewAnswer,
    TopicReviewInput,
    TopicSuggestion,
    suggestion_fingerprint,
)
from agent_core.domain.topics import TopicCreateRequest
from tests.contract.support import NOW, principal
from tests.integration.m2_support import memory_settings


def _suggestion(value: int, text: str, *, topic_id: str = "garden") -> TopicSuggestion:
    owner = principal()
    return TopicSuggestion(
        id=UUID(int=value),
        tenant_id=owner.tenant_id,
        principal_id=owner.principal_id,
        topic_id=topic_id,
        kind=SuggestionKind.INSTRUCTIONS,
        title="Use metric units",
        rationale="You converted to metric in three garden chats this week.",
        instruction_text=text,
        fingerprint=suggestion_fingerprint(SuggestionKind.INSTRUCTIONS, text),
        state=SuggestionState.PROPOSED,
        created_at=NOW,
    )


async def test_the_owner_accepts_or_dismisses_and_dismissals_are_remembered() -> None:
    owner = principal().model_copy(update={"scopes": {"session.read", "session.write"}})
    async with build(settings=memory_settings(), storage="memory", principal=owner) as app:
        api = create_app(
            app.services, app.settings, app.principal, app.new_request_id, app.readiness_probe
        )
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=api, client=("127.0.0.1", 1234)),
            base_url="http://localhost",
        ) as client:
            await client.post(
                "/v1/topics", json={"id": "garden", "name": "Garden", "instructions": "Be brief."}
            )
            async with app.uow_factory() as uow:
                assert await uow.topic_suggestions.add(_suggestion(1, "Use metric units."))
                assert await uow.topic_suggestions.add(_suggestion(2, "Mention frost dates."))
                # The same suggestion again is not a second card.
                assert not await uow.topic_suggestions.add(_suggestion(3, "Use metric units."))

            listed = await client.get("/v1/topics/garden/suggestions")
            assert listed.status_code == 200, listed.text
            assert [row["instruction_text"] for row in listed.json()["items"]] == [
                "Use metric units.",
                "Mention frost dates.",
            ]

            accepted = await client.post(f"/v1/topics/garden/suggestions/{UUID(int=1)}/accept")
            assert accepted.status_code == 200, accepted.text
            assert accepted.json()["state"] == "accepted"
            topic = (await client.get("/v1/topics")).json()["items"][0]
            assert topic["instructions"] == "Be brief.\nUse metric units."

            dismissed = await client.post(f"/v1/topics/garden/suggestions/{UUID(int=2)}/dismiss")
            assert dismissed.json()["state"] == "dismissed"
            again = await client.post(f"/v1/topics/garden/suggestions/{UUID(int=2)}/accept")
            assert again.status_code == 409

            assert (await client.get("/v1/topics/garden/suggestions")).json()["items"] == []
            async with app.uow_factory() as uow:
                assert not await uow.topic_suggestions.add(_suggestion(4, "Mention frost dates."))
            missing = await client.post(f"/v1/topics/garden/suggestions/{UUID(int=99)}/accept")
            assert missing.status_code == 404


class _FakeReviewer:
    def __init__(self, answer: TopicReviewAnswer) -> None:
        self.answer = answer
        self.seen: list[TopicReviewInput] = []

    async def review(self, review: TopicReviewInput, *, principal: Principal) -> TopicReviewAnswer:
        del principal
        self.seen.append(review)
        return self.answer


async def test_a_review_turns_recent_use_into_new_suggestions_only() -> None:
    owner = principal().model_copy(update={"scopes": {"session.read", "session.write"}})
    async with build(settings=memory_settings(), storage="memory", principal=owner) as app:
        topics = app.services.topics
        assert topics is not None
        await topics.create(owner, TopicCreateRequest(id="garden", name="Garden"))
        session = await app.services.sessions.create(owner, "general", {}, topic_id="garden")
        async with app.uow_factory() as uow:
            await uow.events.append(
                NewEvent(
                    session_id=session.id,
                    run_id=None,
                    event_type="user.message.created",
                    actor_type="principal",
                    actor_id=owner.principal_id,
                    payload={"content": "How much water in litres for bed three?"},
                )
            )
            await uow.topic_suggestions.add(_suggestion(10, "Mention frost dates."))
        await topics.dismiss_suggestion(owner, "garden", UUID(int=10))
        weekly = ScheduleDraft(
            title="Saturday watering check",
            instruction="List which beds need water this weekend.",
            cadence=WeeklyCadence(local_time=time(8, 0), weekdays=(5,), timezone="UTC"),
        )
        reviewer = _FakeReviewer(
            TopicReviewAnswer(
                suggestions=[
                    ReviewedSuggestion(
                        kind=SuggestionKind.INSTRUCTIONS,
                        title="Use metric units",
                        rationale="You asked in litres.",
                        instruction_text="Use metric units.",
                    ),
                    ReviewedSuggestion(
                        kind=SuggestionKind.INSTRUCTIONS,
                        title="Frost dates",
                        rationale="Seasonal.",
                        instruction_text="Mention frost dates.",
                    ),
                    ReviewedSuggestion(
                        kind=SuggestionKind.SCHEDULE,
                        title="Weekly watering check",
                        rationale="You ask about watering on weekends.",
                        schedule=weekly,
                    ),
                ]
            )
        )
        service = PublicTopicService(
            uow_factory=app.uow_factory, clock=app.clock, ids=app.ids, reviewer=reviewer
        )
        made = await service.review(owner, "garden")
        assert [item.title for item in made] == ["Use metric units", "Weekly watering check"]
        assert made[1].schedule == weekly
        seen = reviewer.seen[0]
        assert seen.topic_name == "Garden"
        assert seen.recent_user_messages == ["How much water in litres for bed three?"]
        assert seen.dismissed == ["Mention frost dates."]
        assert await service.review(owner, "garden") == []
