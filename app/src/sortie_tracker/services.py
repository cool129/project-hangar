"""Business rules for aircraft and sorties.

Rule violations raise BusinessRuleViolation with a stable `rule` name. The API
returns it in the error body, logs it, and counts it in Prometheus, so a spike
in a specific rule shows up on a dashboard and is searchable in logs.
"""

from datetime import UTC, datetime

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from sortie_tracker import metrics
from sortie_tracker.models import Aircraft, AircraftStatus, Sortie, SortieStatus
from sortie_tracker.schemas import ReadinessReport, SortieCreate, SortieTransition

ALLOWED_TRANSITIONS: dict[SortieStatus, set[SortieStatus]] = {
    SortieStatus.SCHEDULED: {SortieStatus.AIRBORNE, SortieStatus.CANCELLED},
    SortieStatus.AIRBORNE: {SortieStatus.LANDED, SortieStatus.ABORTED},
    SortieStatus.LANDED: set(),
    SortieStatus.CANCELLED: set(),
    SortieStatus.ABORTED: set(),
}


class BusinessRuleViolation(Exception):
    def __init__(self, rule: str, detail: str, status_code: int = 409) -> None:
        super().__init__(detail)
        self.rule = rule
        self.detail = detail
        self.status_code = status_code


class NotFoundError(Exception):
    pass


def _utc(dt: datetime) -> datetime:
    # SQLite (unit tests) returns naive datetimes; PostgreSQL returns aware ones.
    return dt if dt.tzinfo else dt.replace(tzinfo=UTC)


def get_aircraft(session: Session, aircraft_id: int) -> Aircraft:
    aircraft = session.get(Aircraft, aircraft_id)
    if aircraft is None:
        raise NotFoundError(f"Aircraft {aircraft_id} not found")
    return aircraft


def get_sortie(session: Session, sortie_id: int) -> Sortie:
    sortie = session.get(Sortie, sortie_id)
    if sortie is None:
        raise NotFoundError(f"Sortie {sortie_id} not found")
    return sortie


def schedule_sortie(session: Session, data: SortieCreate) -> Sortie:
    aircraft = get_aircraft(session, data.aircraft_id)
    if aircraft.status == AircraftStatus.NMC:
        raise BusinessRuleViolation(
            "aircraft_not_mission_capable",
            f"Aircraft {aircraft.tail_number} is NMC and cannot be scheduled",
        )
    sortie = Sortie(**data.model_dump(), status=SortieStatus.SCHEDULED)
    session.add(sortie)
    session.commit()
    metrics.SORTIES_CREATED.labels(mission_type=sortie.mission_type.value).inc()
    return sortie


def transition_sortie(session: Session, sortie_id: int, change: SortieTransition) -> Sortie:
    sortie = get_sortie(session, sortie_id)
    current, target = sortie.status, change.status

    if target not in ALLOWED_TRANSITIONS[current]:
        raise BusinessRuleViolation(
            "invalid_status_transition", f"Cannot move sortie from {current} to {target}"
        )

    aircraft = sortie.aircraft
    now = datetime.now(UTC)

    if target == SortieStatus.AIRBORNE:
        if aircraft.status == AircraftStatus.NMC:
            raise BusinessRuleViolation(
                "aircraft_not_mission_capable",
                f"Aircraft {aircraft.tail_number} is NMC and cannot launch",
            )
        already_airborne = session.scalar(
            select(func.count())
            .select_from(Sortie)
            .where(
                Sortie.aircraft_id == aircraft.id,
                Sortie.status == SortieStatus.AIRBORNE,
                Sortie.id != sortie.id,
            )
        )
        if already_airborne:
            raise BusinessRuleViolation(
                "aircraft_already_airborne",
                f"Aircraft {aircraft.tail_number} is already flying another sortie",
            )
        sortie.actual_takeoff = now

    if target in (SortieStatus.LANDED, SortieStatus.ABORTED):
        sortie.actual_landing = now
        if sortie.actual_takeoff is not None:
            hours = (now - _utc(sortie.actual_takeoff)).total_seconds() / 3600
            aircraft.total_flight_hours = round(aircraft.total_flight_hours + hours, 2)
        if change.maintenance_required:
            aircraft.status = AircraftStatus.NMC

    if change.notes:
        sortie.notes = change.notes
    sortie.status = target
    session.commit()

    metrics.SORTIE_TRANSITIONS.labels(from_status=current.value, to_status=target.value).inc()
    return sortie


def readiness_report(session: Session) -> ReadinessReport:
    aircraft_counts = dict(
        session.execute(select(Aircraft.status, func.count()).group_by(Aircraft.status)).all()
    )
    sortie_counts = dict(
        session.execute(select(Sortie.status, func.count()).group_by(Sortie.status)).all()
    )
    by_status = {s: aircraft_counts.get(s, 0) for s in AircraftStatus}
    total = sum(by_status.values())
    capable = by_status[AircraftStatus.FMC] + by_status[AircraftStatus.PMC]
    return ReadinessReport(
        total_aircraft=total,
        aircraft_by_status=by_status,
        mission_capable_rate=round(capable / total, 4) if total else 0.0,
        sorties_by_status={s: sortie_counts.get(s, 0) for s in SortieStatus},
    )
