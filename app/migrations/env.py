"""Alembic environment: uses the application's own Settings and metadata."""

from logging.config import fileConfig

from alembic import context
from sqlalchemy import create_engine, pool, text
from sqlalchemy.engine import make_url

from sortie_tracker import models  # noqa: F401 - registers tables on Base.metadata
from sortie_tracker.config import Settings
from sortie_tracker.db import Base

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata

# Every pod runs migrations in an init container. A session-level advisory lock
# makes concurrent runs queue up: the first applies pending revisions, the rest
# find the schema already at head and exit. Released when the connection closes.
MIGRATION_LOCK_ID = 7_302_026  # arbitrary, constant across releases


def _database_url():
    # Tests (and tooling) may inject a URL; otherwise use app settings.
    override = config.attributes.get("database_url")
    return make_url(override) if override else Settings().sqlalchemy_url()


def run_migrations_offline() -> None:
    context.configure(
        url=_database_url(),
        target_metadata=target_metadata,
        literal_binds=True,
        compare_type=True,
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    engine = create_engine(_database_url(), poolclass=pool.NullPool)
    with engine.connect() as connection:
        if connection.dialect.name == "postgresql":
            connection.execute(text("SELECT pg_advisory_lock(:id)"), {"id": MIGRATION_LOCK_ID})
            # End the implicit transaction so Alembic opens (and commits) its own;
            # the session-level lock survives the commit.
            connection.commit()
        context.configure(connection=connection, target_metadata=target_metadata, compare_type=True)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
