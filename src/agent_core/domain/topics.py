"""Topics: one agent and dashboard per area of the owner's life (topics/ARCHITECTURE.md)."""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field, field_validator

# "core" names the shared layer in the API (memory browsing ?topic=core).
RESERVED_TOPIC_IDS = frozenset({"core"})
TOPIC_ID_PATTERN = r"^[a-z0-9][a-z0-9-]{0,63}$"


class Topic(BaseModel):
    """A topic the owner created. Sealed topics share nothing outside themselves."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    id: str = Field(pattern=TOPIC_ID_PATTERN)
    tenant_id: str = Field(min_length=1)
    principal_id: str = Field(min_length=1)
    name: str = Field(min_length=1, max_length=120)
    # The owner's standing instructions to this topic's agent.
    instructions: str = Field(default="", max_length=8000)
    # Not enforced since 2026-10-21 (topics/ARCHITECTURE.md); kept for the column.
    sealed: bool = False
    created_at: datetime
    updated_at: datetime

    @field_validator("id")
    @classmethod
    def not_reserved(cls, value: str) -> str:
        if value in RESERVED_TOPIC_IDS:
            raise ValueError("topic id is reserved")
        return value


class TopicView(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    id: str
    name: str
    instructions: str
    sealed: bool
    created_at: datetime
    updated_at: datetime

    @classmethod
    def from_topic(cls, topic: Topic) -> TopicView:
        return cls(
            id=topic.id,
            name=topic.name,
            instructions=topic.instructions,
            sealed=topic.sealed,
            created_at=topic.created_at,
            updated_at=topic.updated_at,
        )


class TopicCreateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str = Field(pattern=TOPIC_ID_PATTERN)
    name: str = Field(min_length=1, max_length=120)
    instructions: str = Field(default="", max_length=8000)
    sealed: bool = False

    @field_validator("id")
    @classmethod
    def not_reserved(cls, value: str) -> str:
        if value in RESERVED_TOPIC_IDS:
            raise ValueError("topic id is reserved")
        return value


class TopicUpdateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str | None = Field(default=None, min_length=1, max_length=120)
    instructions: str | None = Field(default=None, max_length=8000)
    sealed: bool | None = None
