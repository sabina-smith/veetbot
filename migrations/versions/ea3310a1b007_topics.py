"""Topic registry: an owner's topics and whether each is sealed (topics/ARCHITECTURE.md)."""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "ea3310a1b007"
down_revision: str | Sequence[str] | None = "ea3310a1b006"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "topics",
        sa.Column("tenant_id", sa.Text(), nullable=False),
        sa.Column("principal_id", sa.Text(), nullable=False),
        sa.Column("id", sa.Text(), nullable=False),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("sealed", sa.Boolean(), server_default=sa.text("false"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("tenant_id", "principal_id", "id", name=op.f("pk_topics")),
    )


def downgrade() -> None:
    op.drop_table("topics")
