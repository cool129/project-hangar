import random

from sqlalchemy import func, select

from sortie_tracker.config import Settings
from sortie_tracker.models import Aircraft, Sortie
from sortie_tracker.seed import seed


def test_reads_key_vault_csi_secret_files(tmp_path, monkeypatch):
    secrets = tmp_path / "secrets-store"
    secrets.mkdir()
    (secrets / "postgres-host").write_text("psql-hangar-dev.postgres.database.azure.com\n")
    (secrets / "postgres-database").write_text("sortie_tracker")
    (secrets / "postgres-admin-username").write_text("hangaradmin")
    (secrets / "postgres-admin-password").write_text("s3cr3t!")
    monkeypatch.setenv("SECRETS_DIR", str(secrets))

    settings = Settings()
    assert settings.db_host == "psql-hangar-dev.postgres.database.azure.com"
    assert settings.db_user == "hangaradmin"
    assert settings.db_password.get_secret_value() == "s3cr3t!"


def test_environment_overrides_secret_files(tmp_path, monkeypatch):
    secrets = tmp_path / "secrets-store"
    secrets.mkdir()
    (secrets / "postgres-host").write_text("from-key-vault")
    monkeypatch.setenv("SECRETS_DIR", str(secrets))
    monkeypatch.setenv("DB_HOST", "from-env")

    assert Settings().db_host == "from-env"


def test_url_enforces_tls_and_hides_password():
    settings = Settings(db_host="db", db_user="u", db_password="p@ss", db_name="sortie_tracker")
    url = settings.sqlalchemy_url()
    assert url.drivername == "postgresql+psycopg"
    assert url.query["sslmode"] == "require"
    assert "p@ss" not in str(url)
    assert "p@ss" not in repr(settings)


def test_seed_is_deterministic(app):
    session = app.state.session_factory()
    seed(session, aircraft_count=10, sortie_count=50, rng=random.Random(7))

    assert session.scalar(select(func.count()).select_from(Aircraft)) == 10
    assert session.scalar(select(func.count()).select_from(Sortie)) == 50
    first_tail = session.scalar(select(Aircraft.tail_number).order_by(Aircraft.id))
    assert first_tail == "80-1000"
    session.close()
