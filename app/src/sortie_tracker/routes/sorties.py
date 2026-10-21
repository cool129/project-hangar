from typing import Annotated

from fastapi import APIRouter, Depends, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from sortie_tracker import services
from sortie_tracker.db import get_session
from sortie_tracker.models import MissionType, Sortie, SortieStatus
from sortie_tracker.schemas import SortieCreate, SortieRead, SortieTransition

router = APIRouter(prefix="/api/v1", tags=["sorties"])
SessionDep = Annotated[Session, Depends(get_session)]


@router.get("/sorties", response_model=list[SortieRead])
def list_sorties(
    session: SessionDep,
    status_filter: Annotated[SortieStatus | None, Query(alias="status")] = None,
    aircraft_id: int | None = None,
    mission_type: MissionType | None = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> list[Sortie]:
    query = select(Sortie).order_by(Sortie.scheduled_takeoff.desc()).limit(limit).offset(offset)
    if status_filter is not None:
        query = query.where(Sortie.status == status_filter)
    if aircraft_id is not None:
        query = query.where(Sortie.aircraft_id == aircraft_id)
    if mission_type is not None:
        query = query.where(Sortie.mission_type == mission_type)
    return list(session.scalars(query))


@router.post("/sorties", response_model=SortieRead, status_code=status.HTTP_201_CREATED)
def schedule_sortie(session: SessionDep, data: SortieCreate) -> Sortie:
    return services.schedule_sortie(session, data)


@router.get("/sorties/{sortie_id}", response_model=SortieRead)
def get_sortie(session: SessionDep, sortie_id: int) -> Sortie:
    return services.get_sortie(session, sortie_id)


@router.post("/sorties/{sortie_id}/transition", response_model=SortieRead)
def transition_sortie(session: SessionDep, sortie_id: int, change: SortieTransition) -> Sortie:
    return services.transition_sortie(session, sortie_id, change)
