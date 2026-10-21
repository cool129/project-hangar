from collections.abc import Iterator
from datetime import UTC, datetime, timedelta

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from sortie_tracker.config import Settings
from sortie_tracker.db import Base
from sortie_tracker.main import create_app


@pytest.fixture(autouse=True)
def _isolate_secrets_dir(tmp_path, monkeypatch):
    # Never read a real /mnt/secrets-store during tests.
    monkeypatch.setenv("SECRETS_DIR", str(tmp_path / "no-secrets"))


@pytest.fixture
def settings() -> Settings:
    return Settings(database_url="sqlite+pysqlite:///:memory:", app_env="test", git_sha="abc123")


@pytest.fixture
def app(settings) -> Iterator[FastAPI]:
    application = create_app(settings)
    # Keep our own handle: tests may swap app.state.engine to simulate outages.
    engine = application.state.engine
    Base.metadata.create_all(engine)
    yield application
    Base.metadata.drop_all(engine)
    engine.dispose()


@pytest.fixture
def client(app) -> Iterator[TestClient]:
    with TestClient(app, raise_server_exceptions=False) as test_client:
        yield test_client


@pytest.fixture
def make_aircraft(client):
    counter = iter(range(1000, 9999))

    def _make(**overrides) -> dict:
        body = {
            "tail_number": f"88-{next(counter)}",
            "airframe": "F-16C",
            "unit": "13th Fighter Squadron",
        } | overrides
        response = client.post("/api/v1/aircraft", json=body)
        assert response.status_code == 201, response.text
        return response.json()

    return _make


@pytest.fixture
def make_sortie(client):
    counter = iter(range(1, 9999))

    def _make(aircraft_id: int, **overrides) -> dict:
        body = {
            "mission_number": f"SRT-{next(counter):06d}",
            "aircraft_id": aircraft_id,
            "mission_type": "TRAINING",
            "pilot_callsign": "VIPER 11",
            "scheduled_takeoff": (datetime.now(UTC) + timedelta(hours=2)).isoformat(),
        } | overrides
        return client.post("/api/v1/sorties", json=body)

    return _make
