"""Generate realistic squadron data.

Used locally, by the Ansible legacy_app role to give the legacy VM real data
to migrate, and by load tests. Deterministic for a given --seed.

    sortie-tracker-seed --aircraft 24 --sorties 300 --if-empty
"""

import argparse
import logging
import random
from datetime import UTC, datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from sortie_tracker.config import get_settings
from sortie_tracker.db import build_engine, build_session_factory
from sortie_tracker.logging_config import configure_logging
from sortie_tracker.models import (
    Aircraft,
    AircraftStatus,
    MissionType,
    Sortie,
    SortieStatus,
)

logger = logging.getLogger(__name__)

UNITS = {
    "F-16C": "13th Fighter Squadron",
    "F-35A": "421st Fighter Squadron",
    "KC-135R": "92nd Air Refueling Squadron",
    "C-17A": "4th Airlift Squadron",
    "MQ-9A": "15th Attack Squadron",
}
MISSIONS_BY_AIRFRAME = {
    "F-16C": [MissionType.TRAINING, MissionType.COMBAT_AIR_PATROL, MissionType.CLOSE_AIR_SUPPORT],
    "F-35A": [MissionType.TRAINING, MissionType.COMBAT_AIR_PATROL, MissionType.ISR],
    "KC-135R": [MissionType.TRAINING, MissionType.AERIAL_REFUELING],
    "C-17A": [MissionType.TRAINING, MissionType.AIRLIFT],
    "MQ-9A": [MissionType.ISR, MissionType.CLOSE_AIR_SUPPORT],
}
CALLSIGNS = ["VIPER", "HAWK", "RAZOR", "SHELL", "REACH", "REAPER", "BOLT", "JAKE"]


def seed(session: Session, aircraft_count: int, sortie_count: int, rng: random.Random) -> None:
    airframes = list(UNITS)
    fleet: list[Aircraft] = []
    for i in range(aircraft_count):
        airframe = airframes[i % len(airframes)]
        fleet.append(
            Aircraft(
                # USAF serial style: fiscal year - sequence, e.g. 88-0412.
                tail_number=f"{80 + i % 20:02d}-{1000 + i:04d}",
                airframe=airframe,
                unit=UNITS[airframe],
                status=rng.choices(list(AircraftStatus), weights=[75, 12, 13])[0],
                total_flight_hours=round(rng.uniform(800, 6000), 1),
            )
        )
    session.add_all(fleet)
    session.flush()

    now = datetime.now(UTC)
    for n in range(sortie_count):
        aircraft = rng.choice(fleet)
        scheduled = now - timedelta(days=rng.uniform(0, 60)) + timedelta(days=2)
        if scheduled > now:
            status = SortieStatus.SCHEDULED
        else:
            status = rng.choices(
                [SortieStatus.LANDED, SortieStatus.CANCELLED, SortieStatus.ABORTED],
                weights=[85, 10, 5],
            )[0]
        takeoff = landing = None
        if status in (SortieStatus.LANDED, SortieStatus.ABORTED):
            takeoff = scheduled + timedelta(minutes=rng.randint(-5, 25))
            min_hours = 0.3 if status == SortieStatus.ABORTED else 1.0
            landing = takeoff + timedelta(hours=rng.uniform(min_hours, 6))
        session.add(
            Sortie(
                mission_number=f"SRT-{n + 1:06d}",
                aircraft_id=aircraft.id,
                mission_type=rng.choice(MISSIONS_BY_AIRFRAME[aircraft.airframe]),
                status=status,
                pilot_callsign=f"{rng.choice(CALLSIGNS)} {rng.randint(1, 4)}{rng.randint(1, 4)}",
                scheduled_takeoff=scheduled,
                actual_takeoff=takeoff,
                actual_landing=landing,
            )
        )
    session.commit()


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--aircraft", type=int, default=24)
    parser.add_argument("--sorties", type=int, default=300)
    parser.add_argument("--seed", type=int, default=42, help="RNG seed for reproducible data")
    parser.add_argument(
        "--if-empty", action="store_true", help="Do nothing if aircraft already exist (idempotent)"
    )
    args = parser.parse_args(argv)

    settings = get_settings()
    configure_logging(settings.log_level)
    engine = build_engine(settings)
    with build_session_factory(engine)() as session:
        existing = session.scalar(select(func.count()).select_from(Aircraft)) or 0
        if args.if_empty and existing:
            logger.info("seed_skipped", extra={"existing_aircraft": existing})
            return
        seed(session, args.aircraft, args.sorties, random.Random(args.seed))  # noqa: S311
    logger.info("seed_complete", extra={"aircraft": args.aircraft, "sorties": args.sorties})


if __name__ == "__main__":
    main()
