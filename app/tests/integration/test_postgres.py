"""Integration tests against real PostgreSQL.

    docker compose up -d db
    TEST_DATABASE_URL=postgresql+psycopg://sortie:local-dev-only@127.0.0.1:55432/sortie_tracker \
        pytest -m integration      (or: make app-test-integration)

Skipped automatically when TEST_DATABASE_URL is unset. The tests downgrade the
schema to base, so point them at a disposable database.
"""

import os
from pathlib import Path

import pytest
from alembic import command
from alembic.autogenerate import compare_metadata
from alembic.config import Config
from alembic.migration import MigrationContext
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, inspect

from sortie_tracker.config import Settings
from sortie_tracker.db import Base
from sortie_tracker.main import create_app

DATABASE_URL = os.environ.get("TEST_DATABASE_URL")
APP_DIR = Path(__file__).resolve().parents[2]

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(not DATABASE_URL, reason="TEST_DATABASE_URL not set"),
]


@pytest.fixture
def alembic_config() -> Config:
    config = Config(str(APP_DIR / "alembic.ini"))
    config.attributes["database_url"] = DATABASE_URL
    return config


@pytest.fixture
def migrated_db(alembic_config):
    command.downgrade(alembic_config, "base")
    command.upgrade(alembic_config, "head")
    yield
    command.downgrade(alembic_config, "base")


def test_migrations_upgrade_and_downgrade_cleanly(alembic_config):
    command.downgrade(alembic_config, "base")
    command.upgrade(alembic_config, "head")
    tables = set(inspect(create_engine(DATABASE_URL)).get_table_names())
    assert {"aircraft", "sorties", "alembic_version"} <= tables

    command.downgrade(alembic_config, "base")
    assert inspect(create_engine(DATABASE_URL)).get_table_names() == ["alembic_version"]


def test_migrations_match_models(migrated_db):
    """Fails if someone changes a model without writing a migration."""
    engine = create_engine(DATABASE_URL)
    with engine.connect() as conn:
        diff = compare_metadata(MigrationContext.configure(conn), Base.metadata)
    assert diff == [], f"Schema drift between models and migrations: {diff}"


def test_api_against_postgres(migrated_db):
    app = create_app(Settings(database_url=DATABASE_URL, app_env="integration"))
    with TestClient(app) as client:
        assert client.get("/readyz").json()["database"] == "ok"

        aircraft = client.post(
            "/api/v1/aircraft",
            json={"tail_number": "88-0412", "airframe": "F-16C", "unit": "13th Fighter Squadron"},
        ).json()
        sortie = client.post(
            "/api/v1/sorties",
            json={
                "mission_number": "SRT-000001",
                "aircraft_id": aircraft["id"],
                "mission_type": "CLOSE_AIR_SUPPORT",
                "pilot_callsign": "HAWK 21",
                "scheduled_takeoff": "2026-10-21T14:00:00Z",
            },
        ).json()
        assert sortie["scheduled_takeoff"].startswith("2026-10-21T14:00:00")

        client.post(f"/api/v1/sorties/{sortie['id']}/transition", json={"status": "AIRBORNE"})
        landed = client.post(
            f"/api/v1/sorties/{sortie['id']}/transition", json={"status": "LANDED"}
        ).json()
        assert landed["status"] == "LANDED"

        # PostgreSQL's unique index surfaces as a clean 409, not a 500.
        duplicate = client.post(
            "/api/v1/aircraft",
            json={"tail_number": "88-0412", "airframe": "F-16C", "unit": "13th Fighter Squadron"},
        )
        assert duplicate.status_code == 409
    app.state.engine.dispose()
