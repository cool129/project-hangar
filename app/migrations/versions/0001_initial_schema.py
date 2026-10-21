"""Initial schema: aircraft and sorties.

Revision ID: 0001
Revises:
Create Date: 2026-10-20
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

AIRCRAFT_STATUS = ("FMC", "PMC", "NMC")
MISSION_TYPE = (
    "TRAINING",
    "COMBAT_AIR_PATROL",
    "CLOSE_AIR_SUPPORT",
    "ISR",
    "AIRLIFT",
    "AERIAL_REFUELING",
)
SORTIE_STATUS = ("SCHEDULED", "AIRBORNE", "LANDED", "CANCELLED", "ABORTED")


def _enum(values: tuple[str, ...], name: str) -> sa.Enum:
    return sa.Enum(*values, name=name, native_enum=False, create_constraint=True, length=32)


def _timestamps() -> list[sa.Column]:
    return [
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
    ]


def upgrade() -> None:
    op.create_table(
        "aircraft",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("tail_number", sa.String(16), nullable=False),
        sa.Column("airframe", sa.String(32), nullable=False),
        sa.Column("unit", sa.String(64), nullable=False),
        sa.Column("status", _enum(AIRCRAFT_STATUS, "aircraft_status"), nullable=False),
        sa.Column("total_flight_hours", sa.Float(), nullable=False),
        *_timestamps(),
        sa.PrimaryKeyConstraint("id", name="pk_aircraft"),
    )
    op.create_index("ix_aircraft_tail_number", "aircraft", ["tail_number"], unique=True)
    op.create_index("ix_aircraft_unit", "aircraft", ["unit"])

    op.create_table(
        "sorties",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("mission_number", sa.String(32), nullable=False),
        sa.Column("aircraft_id", sa.Integer(), nullable=False),
        sa.Column("mission_type", _enum(MISSION_TYPE, "mission_type"), nullable=False),
        sa.Column("status", _enum(SORTIE_STATUS, "sortie_status"), nullable=False),
        sa.Column("pilot_callsign", sa.String(32), nullable=False),
        sa.Column("scheduled_takeoff", sa.DateTime(timezone=True), nullable=False),
        sa.Column("actual_takeoff", sa.DateTime(timezone=True), nullable=True),
        sa.Column("actual_landing", sa.DateTime(timezone=True), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        *_timestamps(),
        sa.PrimaryKeyConstraint("id", name="pk_sorties"),
        sa.ForeignKeyConstraint(
            ["aircraft_id"],
            ["aircraft.id"],
            name="fk_sorties_aircraft_id_aircraft",
            ondelete="RESTRICT",
        ),
    )
    op.create_index("ix_sorties_mission_number", "sorties", ["mission_number"], unique=True)
    op.create_index("ix_sorties_aircraft_id", "sorties", ["aircraft_id"])
    op.create_index("ix_sorties_status", "sorties", ["status"])


def downgrade() -> None:
    op.drop_table("sorties")
    op.drop_table("aircraft")
