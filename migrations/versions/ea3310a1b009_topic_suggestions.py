"""Topic suggestions: proposed by a topic's agent, decided by the owner (topics/ARCHITECTURE.md)."""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "ea3310a1b009"
down_revision: str | Sequence[str] | None = "ea3310a1b008"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "topic_suggestions",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.Text(), nullable=False),
        sa.Column("principal_id", sa.Text(), nullable=False),
        sa.Column("topic_id", sa.Text(), nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("title", sa.Text(), nullable=False),
        sa.Column("rationale", sa.Text(), nullable=False),
        sa.Column("instruction_text", sa.Text(), nullable=True),
        sa.Column("schedule", postgresql.JSONB(astext_type=sa.Text()), nullable=True),
        sa.Column("fingerprint", sa.Text(), nullable=False),
        sa.Column("state", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("decided_at", sa.DateTime(timezone=True), nullable=True),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_topic_suggestions")),
        sa.UniqueConstraint(
            "tenant_id",
            "principal_id",
            "topic_id",
            "fingerprint",
            name="uq_topic_suggestions_fingerprint",
        ),
    )
    op.create_index(
        "ix_topic_suggestions_topic",
        "topic_suggestions",
        ["tenant_id", "principal_id", "topic_id", "created_at"],
    )


def downgrade() -> None:
    op.drop_index("ix_topic_suggestions_topic", table_name="topic_suggestions")
    op.drop_table("topic_suggestions")
