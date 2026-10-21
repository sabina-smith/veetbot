"""Topic walls: a nullable topic on memories and sessions; NULL is core (topics/ARCHITECTURE.md)."""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "ea3310a1b006"
down_revision: str | Sequence[str] | None = "ea3310a1b005"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # Existing beliefs and sessions become core, so current behavior is unchanged.
    op.add_column("memories", sa.Column("topic_id", sa.Text(), nullable=True))
    op.add_column("sessions", sa.Column("topic_id", sa.Text(), nullable=True))
    op.create_index(
        "ix_memories_principal_topic",
        "memories",
        ["tenant_id", "principal_id", "topic_id"],
    )


def downgrade() -> None:
    op.drop_index("ix_memories_principal_topic", table_name="memories")
    op.drop_column("sessions", "topic_id")
    op.drop_column("memories", "topic_id")
