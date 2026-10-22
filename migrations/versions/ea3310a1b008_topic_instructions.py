"""Topic agents: the owner's standing instructions per topic (topics/ARCHITECTURE.md)."""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "ea3310a1b008"
down_revision: str | Sequence[str] | None = "ea3310a1b007"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "topics",
        sa.Column("instructions", sa.Text(), server_default=sa.text("''"), nullable=False),
    )


def downgrade() -> None:
    op.drop_column("topics", "instructions")
