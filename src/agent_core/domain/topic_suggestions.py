"""Suggestions a topic's agent makes from how the owner uses the topic (topics/ARCHITECTURE.md).

Nothing changes until the owner accepts. A dismissed suggestion's fingerprint
is remembered so the same suggestion is never made again.
"""

from __future__ import annotations

import hashlib
from datetime import datetime
from enum import StrEnum
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator

from agent_core.domain.schedules import Cadence


class SuggestionKind(StrEnum):
    INSTRUCTIONS = "instructions"
    SCHEDULE = "schedule"


class SuggestionState(StrEnum):
    PROPOSED = "proposed"
    ACCEPTED = "accepted"
    DISMISSED = "dismissed"


class ScheduleDraft(BaseModel):
    """A recurring check-in the topic's agent would run if the owner accepts."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    title: str = Field(min_length=1, max_length=200)
    instruction: str = Field(min_length=1, max_length=2000)
    cadence: Cadence


def suggestion_fingerprint(kind: SuggestionKind, content: str) -> str:
    normalized = " ".join(content.split()).casefold()
    return hashlib.sha256(f"{kind.value}\n{normalized}".encode()).hexdigest()


class TopicSuggestion(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    id: UUID
    tenant_id: str = Field(min_length=1)
    principal_id: str = Field(min_length=1)
    topic_id: str = Field(min_length=1, max_length=128)
    kind: SuggestionKind
    title: str = Field(min_length=1, max_length=200)
    # Why, in terms of what the owner did; shown with the suggestion.
    rationale: str = Field(min_length=1, max_length=1000)
    instruction_text: str | None = Field(default=None, min_length=1, max_length=1000)
    schedule: ScheduleDraft | None = None
    fingerprint: str = Field(pattern=r"^[0-9a-f]{64}$")
    state: SuggestionState
    created_at: datetime
    decided_at: datetime | None = None

    @model_validator(mode="after")
    def content_matches_kind(self) -> TopicSuggestion:
        if self.kind is SuggestionKind.INSTRUCTIONS and (
            self.instruction_text is None or self.schedule is not None
        ):
            raise ValueError("an instructions suggestion carries instruction_text only")
        if self.kind is SuggestionKind.SCHEDULE and (
            self.schedule is None or self.instruction_text is not None
        ):
            raise ValueError("a schedule suggestion carries a schedule only")
        return self


class TopicSuggestionView(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    id: UUID
    topic_id: str
    kind: SuggestionKind
    title: str
    rationale: str
    instruction_text: str | None
    schedule: ScheduleDraft | None
    state: SuggestionState
    created_at: datetime
    decided_at: datetime | None

    @classmethod
    def from_suggestion(cls, suggestion: TopicSuggestion) -> TopicSuggestionView:
        return cls(
            id=suggestion.id,
            topic_id=suggestion.topic_id,
            kind=suggestion.kind,
            title=suggestion.title,
            rationale=suggestion.rationale,
            instruction_text=suggestion.instruction_text,
            schedule=suggestion.schedule,
            state=suggestion.state,
            created_at=suggestion.created_at,
            decided_at=suggestion.decided_at,
        )


class ReviewedSuggestion(BaseModel):
    """One suggestion as the review model returns it, before it is stored."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    kind: SuggestionKind
    title: str = Field(min_length=1, max_length=200)
    rationale: str = Field(min_length=1, max_length=1000)
    instruction_text: str | None = Field(default=None, min_length=1, max_length=1000)
    schedule: ScheduleDraft | None = None


class TopicReviewAnswer(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    suggestions: list[ReviewedSuggestion] = Field(default_factory=list, max_length=3)


class TopicReviewInput(BaseModel):
    """What a topic review sees: the topic, recent use, and past decisions."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    topic_name: str
    instructions: str
    recent_user_messages: list[str]
    accepted: list[str]
    dismissed: list[str]
