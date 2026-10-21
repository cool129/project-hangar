from typing import Annotated

from fastapi import APIRouter, Depends, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from sortie_tracker import services
from sortie_tracker.db import get_session
from sortie_tracker.models import Aircraft, AircraftStatus
from sortie_tracker.schemas import AircraftCreate, AircraftRead, AircraftUpdate, ReadinessReport

router = APIRouter(prefix="/api/v1", tags=["aircraft"])
SessionDep = Annotated[Session, Depends(get_session)]


@router.get("/aircraft", response_model=list[AircraftRead])
def list_aircraft(
    session: SessionDep,
    status_filter: Annotated[AircraftStatus | None, Query(alias="status")] = None,
    unit: str | None = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> list[Aircraft]:
    query = select(Aircraft).order_by(Aircraft.tail_number).limit(limit).offset(offset)
    if status_filter is not None:
        query = query.where(Aircraft.status == status_filter)
    if unit is not None:
        query = query.where(Aircraft.unit == unit)
    return list(session.scalars(query))


@router.post("/aircraft", response_model=AircraftRead, status_code=status.HTTP_201_CREATED)
def create_aircraft(session: SessionDep, data: AircraftCreate) -> Aircraft:
    aircraft = Aircraft(**data.model_dump())
    session.add(aircraft)
    session.commit()  # duplicate tail_number -> IntegrityError -> 409 (see main.py)
    return aircraft


@router.get("/aircraft/{aircraft_id}", response_model=AircraftRead)
def get_aircraft(session: SessionDep, aircraft_id: int) -> Aircraft:
    return services.get_aircraft(session, aircraft_id)


@router.patch("/aircraft/{aircraft_id}", response_model=AircraftRead)
def update_aircraft(session: SessionDep, aircraft_id: int, data: AircraftUpdate) -> Aircraft:
    aircraft = services.get_aircraft(session, aircraft_id)
    for field, value in data.model_dump(exclude_unset=True, exclude_none=True).items():
        setattr(aircraft, field, value)
    session.commit()
    return aircraft


@router.get("/readiness", response_model=ReadinessReport, tags=["readiness"])
def readiness_report(session: SessionDep) -> ReadinessReport:
    return services.readiness_report(session)
