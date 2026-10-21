"""Request/response models (the API contract, decoupled from the ORM)."""

from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field

from sortie_tracker.models import AircraftStatus, MissionType, SortieStatus


class AircraftCreate(BaseModel):
    tail_number: str = Field(min_length=3, max_length=16, examples=["88-0412"])
    airframe: str = Field(min_length=2, max_length=32, examples=["F-16C"])
    unit: str = Field(min_length=2, max_length=64, examples=["36th Fighter Squadron"])
    status: AircraftStatus = AircraftStatus.FMC


class AircraftUpdate(BaseModel):
    unit: str | None = Field(default=None, min_length=2, max_length=64)
    status: AircraftStatus | None = None


class AircraftRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    tail_number: str
    airframe: str
    unit: str
    status: AircraftStatus
    total_flight_hours: float
    created_at: datetime
    updated_at: datetime


class SortieCreate(BaseModel):
    mission_number: str = Field(min_length=3, max_length=32, examples=["SRT-000123"])
    aircraft_id: int
    mission_type: MissionType
    pilot_callsign: str = Field(min_length=2, max_length=32, examples=["VIPER 11"])
    scheduled_takeoff: datetime
    notes: str | None = Field(default=None, max_length=2000)


class SortieTransition(BaseModel):
    status: SortieStatus
    # Post-flight write-up: grounds the aircraft (NMC) when it lands or aborts.
    maintenance_required: bool = False
    notes: str | None = Field(default=None, max_length=2000)


class SortieRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    mission_number: str
    aircraft_id: int
    mission_type: MissionType
    status: SortieStatus
    pilot_callsign: str
    scheduled_takeoff: datetime
    actual_takeoff: datetime | None
    actual_landing: datetime | None
    notes: str | None
    created_at: datetime
    updated_at: datetime


class ReadinessReport(BaseModel):
    total_aircraft: int
    aircraft_by_status: dict[AircraftStatus, int]
    mission_capable_rate: float = Field(
        description="(FMC + PMC) / total; a core USAF readiness KPI."
    )
    sorties_by_status: dict[SortieStatus, int]


class ErrorResponse(BaseModel):
    detail: str
    rule: str | None = None
    request_id: str | None = None
