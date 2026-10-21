"""ORM models.

Aircraft status uses the USAF mission-capability codes:
  FMC  Fully Mission Capable
  PMC  Partially Mission Capable (can fly some missions)
  NMC  Not Mission Capable (grounded for maintenance or supply)
"""

from datetime import datetime
from enum import StrEnum

from sqlalchemy import DateTime, Enum, Float, ForeignKey, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from sortie_tracker.db import Base


class AircraftStatus(StrEnum):
    FMC = "FMC"
    PMC = "PMC"
    NMC = "NMC"


class MissionType(StrEnum):
    TRAINING = "TRAINING"
    COMBAT_AIR_PATROL = "COMBAT_AIR_PATROL"
    CLOSE_AIR_SUPPORT = "CLOSE_AIR_SUPPORT"
    ISR = "ISR"
    AIRLIFT = "AIRLIFT"
    AERIAL_REFUELING = "AERIAL_REFUELING"


class SortieStatus(StrEnum):
    SCHEDULED = "SCHEDULED"
    AIRBORNE = "AIRBORNE"
    LANDED = "LANDED"
    CANCELLED = "CANCELLED"
    ABORTED = "ABORTED"


def _enum(enum_cls: type[StrEnum], name: str) -> Enum:
    # VARCHAR + CHECK instead of a native PG enum: adding a value is a simple
    # migration and the schema stays portable to SQLite for unit tests.
    return Enum(
        enum_cls,
        name=name,
        native_enum=False,
        create_constraint=True,
        length=32,
        values_callable=lambda e: [m.value for m in e],
    )


class TimestampMixin:
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class Aircraft(TimestampMixin, Base):
    __tablename__ = "aircraft"

    id: Mapped[int] = mapped_column(primary_key=True)
    tail_number: Mapped[str] = mapped_column(String(16), unique=True, index=True)
    airframe: Mapped[str] = mapped_column(String(32))
    unit: Mapped[str] = mapped_column(String(64), index=True)
    status: Mapped[AircraftStatus] = mapped_column(
        _enum(AircraftStatus, "aircraft_status"), default=AircraftStatus.FMC
    )
    total_flight_hours: Mapped[float] = mapped_column(Float, default=0.0)

    sorties: Mapped[list["Sortie"]] = relationship(back_populates="aircraft")


class Sortie(TimestampMixin, Base):
    __tablename__ = "sorties"

    id: Mapped[int] = mapped_column(primary_key=True)
    mission_number: Mapped[str] = mapped_column(String(32), unique=True, index=True)
    aircraft_id: Mapped[int] = mapped_column(
        ForeignKey("aircraft.id", ondelete="RESTRICT"), index=True
    )
    mission_type: Mapped[MissionType] = mapped_column(_enum(MissionType, "mission_type"))
    status: Mapped[SortieStatus] = mapped_column(
        _enum(SortieStatus, "sortie_status"), default=SortieStatus.SCHEDULED, index=True
    )
    pilot_callsign: Mapped[str] = mapped_column(String(32))
    scheduled_takeoff: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    actual_takeoff: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    actual_landing: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    notes: Mapped[str | None] = mapped_column(Text)

    aircraft: Mapped[Aircraft] = relationship(back_populates="sorties")
