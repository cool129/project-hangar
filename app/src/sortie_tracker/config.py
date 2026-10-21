"""Runtime configuration.

Precedence, highest first:
  1. Explicit constructor arguments (tests)
  2. Environment variables (DB_HOST, DB_PASSWORD, ...)
  3. Files mounted by the Key Vault Secrets Store CSI driver
  4. Defaults

Secret files keep their Key Vault names (e.g. ``postgres-admin-password``), so
the names Terraform writes are the names the app reads; no renaming layer.
"""

import os
from functools import lru_cache
from pathlib import Path
from typing import Any

from pydantic import SecretStr
from pydantic.fields import FieldInfo
from pydantic_settings import BaseSettings, PydanticBaseSettingsSource, SettingsConfigDict
from sqlalchemy.engine import URL, make_url

DEFAULT_SECRETS_DIR = "/mnt/secrets-store"

# Key Vault secret name -> Settings field.
KEY_VAULT_SECRET_FIELDS = {
    "postgres-host": "db_host",
    "postgres-database": "db_name",
    "postgres-admin-username": "db_user",
    "postgres-admin-password": "db_password",
}


class SecretsDirSource(PydanticBaseSettingsSource):
    """Reads Key Vault secrets mounted as files by the CSI driver."""

    def __init__(self, settings_cls: type[BaseSettings], secrets_dir: Path) -> None:
        super().__init__(settings_cls)
        self.secrets_dir = secrets_dir

    def get_field_value(self, field: FieldInfo, field_name: str) -> tuple[Any, str, bool]:
        # Unused: __call__ returns all values at once.
        return None, field_name, False

    def __call__(self) -> dict[str, Any]:
        if not self.secrets_dir.is_dir():
            return {}
        values: dict[str, Any] = {}
        for secret_name, field_name in KEY_VAULT_SECRET_FIELDS.items():
            path = self.secrets_dir / secret_name
            if path.is_file():
                values[field_name] = path.read_text(encoding="utf-8").strip()
        return values


class Settings(BaseSettings):
    model_config = SettingsConfigDict(extra="ignore")

    app_name: str = "sortie-tracker"
    app_env: str = "local"
    log_level: str = "INFO"
    git_sha: str = "unknown"

    # Full URL override (tests, ad-hoc tooling). When unset, built from db_* fields.
    database_url: SecretStr | None = None
    db_host: str = "localhost"
    db_port: int = 5432
    db_name: str = "sortie_tracker"
    db_user: str = "postgres"
    db_password: SecretStr = SecretStr("")
    db_sslmode: str = "require"  # Azure enforces TLS; local compose sets "disable"
    db_pool_size: int = 5
    db_max_overflow: int = 5
    db_connect_timeout: int = 5

    @classmethod
    def settings_customise_sources(
        cls,
        settings_cls: type[BaseSettings],
        init_settings: PydanticBaseSettingsSource,
        env_settings: PydanticBaseSettingsSource,
        dotenv_settings: PydanticBaseSettingsSource,
        file_secret_settings: PydanticBaseSettingsSource,
    ) -> tuple[PydanticBaseSettingsSource, ...]:
        secrets_dir = Path(os.environ.get("SECRETS_DIR", DEFAULT_SECRETS_DIR))
        return (init_settings, env_settings, SecretsDirSource(settings_cls, secrets_dir))

    def sqlalchemy_url(self) -> URL:
        if self.database_url is not None:
            return make_url(self.database_url.get_secret_value())
        return URL.create(
            "postgresql+psycopg",
            username=self.db_user,
            password=self.db_password.get_secret_value(),
            host=self.db_host,
            port=self.db_port,
            database=self.db_name,
            query={"sslmode": self.db_sslmode, "connect_timeout": str(self.db_connect_timeout)},
        )


@lru_cache
def get_settings() -> Settings:
    return Settings()
