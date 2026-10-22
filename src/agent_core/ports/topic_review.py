"""The model call behind a topic review (topics/ARCHITECTURE.md)."""

from __future__ import annotations

from typing import Protocol

from agent_core.domain.agents import Principal
from agent_core.domain.topic_suggestions import TopicReviewAnswer, TopicReviewInput


class TopicReviewer(Protocol):
    async def review(self, review: TopicReviewInput, *, principal: Principal) -> TopicReviewAnswer:
        """Propose at most a few suggestions from how the owner used a topic."""
        ...
