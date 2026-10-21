#!/usr/bin/env python3
"""Migrate a PostgreSQL database's data to a schema-identical target and prove it.

Built for the Sortie Tracker legacy-to-AKS migration, but generic: it works on
any application whose schema is managed by Alembic on both sides.

Phases (each recorded in the report):
  1. preflight  both servers reachable, same major version, same Alembic
                revision, target tables empty (unless --allow-nonempty-target)
  2. dump       pg_dump --data-only (custom format) + SHA-256 of the dump
  3. restore    pg_restore --single-transaction: all rows land or none do
  4. sequences  reset every serial/identity sequence to max(id)
  5. validate   per-table row counts and content checksums, source vs target

Connection strings come from SOURCE_DATABASE_URL / TARGET_DATABASE_URL so
passwords never appear in the process list or shell history; pg_dump and
pg_restore receive them through PG* environment variables.

Exit codes: 0 pass, 1 validation mismatch, 2 preflight failure, 3 dump/restore failure.

    SOURCE_DATABASE_URL=... TARGET_DATABASE_URL=... \\
        migrate_db.py --report-dir /var/lib/sortie-tracker/migration/run1
    migrate_db.py --validate-only --report-dir ...   # re-verify an existing copy

Requires: python3, psycopg 3, pg_dump/pg_restore matching the server major version.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime
from pathlib import Path

import psycopg
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict

EXIT_OK, EXIT_MISMATCH, EXIT_PREFLIGHT, EXIT_COPY = 0, 1, 2, 3
SKIP_TABLES = {"alembic_version"}  # schema bookkeeping, owned by migrations


class MigrationError(Exception):
    def __init__(self, message: str, exit_code: int) -> None:
        super().__init__(message)
        self.exit_code = exit_code


@dataclass
class TableResult:
    name: str
    source_rows: int
    target_rows: int
    source_checksum: str
    target_checksum: str

    @property
    def match(self) -> bool:
        return (self.source_rows, self.source_checksum) == (self.target_rows, self.target_checksum)


@dataclass
class Report:
    run_started: str
    mode: str
    result: str = "RUNNING"
    error: str | None = None
    duration_seconds: float = 0.0
    source: dict = field(default_factory=dict)
    target: dict = field(default_factory=dict)
    dump: dict = field(default_factory=dict)
    sequences: list[dict] = field(default_factory=list)
    tables: list[dict] = field(default_factory=list)
    phases: list[dict] = field(default_factory=list)


def log(message: str) -> None:
    print(f"[migrate] {datetime.now(UTC):%H:%M:%S} {message}", flush=True)


def pg_env(url: str) -> dict[str, str]:
    """libpq environment for pg_dump/pg_restore, decoded from a connection URL."""
    params = conninfo_to_dict(url)
    mapping = {
        "host": "PGHOST",
        "port": "PGPORT",
        "dbname": "PGDATABASE",
        "user": "PGUSER",
        "password": "PGPASSWORD",
        "sslmode": "PGSSLMODE",
        "connect_timeout": "PGCONNECT_TIMEOUT",
    }
    env = {k: v for k, v in os.environ.items() if not k.startswith("PG")}
    env.update({mapping[k]: str(v) for k, v in params.items() if k in mapping})
    return env


def connect(url: str) -> psycopg.Connection:
    conn = psycopg.connect(url, autocommit=True, connect_timeout=10)
    # Row text renders timestamps in the session time zone; pin it so checksums
    # from both servers are comparable.
    conn.execute("SET TIME ZONE 'UTC'")
    return conn


def describe(conn: psycopg.Connection) -> dict:
    version = conn.execute("SHOW server_version").fetchone()[0]
    try:
        revision = conn.execute("SELECT version_num FROM alembic_version").fetchone()
    except psycopg.errors.UndefinedTable:
        revision = None
    return {
        "server_version": version,
        "major_version": version.split(".")[0],
        "alembic_revision": revision[0] if revision else None,
    }


def user_tables(conn: psycopg.Connection) -> list[str]:
    rows = conn.execute(
        "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename"
    ).fetchall()
    return [r[0] for r in rows if r[0] not in SKIP_TABLES]


def primary_key(conn: psycopg.Connection, table: str) -> list[str]:
    rows = conn.execute(
        """
        SELECT a.attname
        FROM pg_index i
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        WHERE i.indrelid = %s::regclass AND i.indisprimary
        ORDER BY array_position(i.indkey, a.attnum)
        """,
        (f"public.{table}",),
    ).fetchall()
    if not rows:
        raise MigrationError(f"table {table} has no primary key; cannot checksum", EXIT_PREFLIGHT)
    return [r[0] for r in rows]


def table_fingerprint(conn: psycopg.Connection, table: str) -> tuple[int, str]:
    """Row count + checksum over every column, ordered by primary key (not storage order)."""
    pk = primary_key(conn, table)
    query = sql.SQL(
        "SELECT count(*), md5(coalesce(string_agg(md5(t::text), '' ORDER BY {pk}), '')) "
        "FROM public.{table} AS t"
    ).format(
        pk=sql.SQL(", ").join(sql.SQL("t.") + sql.Identifier(c) for c in pk),
        table=sql.Identifier(table),
    )
    count, checksum = conn.execute(query).fetchone()
    return count, checksum


def run_tool(argv: list[str], env: dict[str, str]) -> None:
    log(" ".join(argv))
    proc = subprocess.run(argv, env=env, capture_output=True, text=True, check=False)  # noqa: S603
    if proc.returncode != 0:
        raise MigrationError(f"{argv[0]} failed: {proc.stderr.strip()}", EXIT_COPY)


def reset_sequences(conn: psycopg.Connection, tables: list[str]) -> list[dict]:
    """pg_restore --data-only does not reliably restore sequence positions."""
    results = []
    for table in tables:
        cols = conn.execute(
            """
            SELECT column_name, pg_get_serial_sequence(%s, column_name)
            FROM information_schema.columns
            WHERE table_schema = 'public' AND table_name = %s
              AND pg_get_serial_sequence(%s, column_name) IS NOT NULL
            """,
            (f"public.{table}", table, f"public.{table}"),
        ).fetchall()
        for column, sequence in cols:
            max_id = conn.execute(
                sql.SQL("SELECT max({c}) FROM public.{t}").format(
                    c=sql.Identifier(column), t=sql.Identifier(table)
                )
            ).fetchone()[0]
            # is_called=false with value 1 makes nextval() return 1 on an empty table.
            conn.execute("SELECT setval(%s, %s, %s)", (sequence, max_id or 1, max_id is not None))
            results.append({"sequence": sequence, "set_to": max_id})
    return results


class Migration:
    def __init__(self, source_url: str, target_url: str, report_dir: Path, args) -> None:
        self.source_url = source_url
        self.target_url = target_url
        self.report_dir = report_dir
        self.args = args
        self.report = Report(
            run_started=datetime.now(UTC).isoformat(timespec="seconds"),
            mode="validate-only" if args.validate_only else "migrate",
        )

    def phase(self, name: str):
        migration = self

        class _Phase:
            def __enter__(self):
                self.start = time.monotonic()
                log(f"== {name}")

            def __exit__(self, exc_type, exc, tb):
                migration.report.phases.append(
                    {
                        "name": name,
                        "seconds": round(time.monotonic() - self.start, 2),
                        "status": "ok" if exc is None else "failed",
                    }
                )
                return False

        return _Phase()

    def run(self) -> int:
        started = time.monotonic()
        try:
            with connect(self.source_url) as src, connect(self.target_url) as dst:
                tables = self.preflight(src, dst)
                if not self.args.validate_only:
                    self.copy(tables)
                    with self.phase("sequences"):
                        self.report.sequences = reset_sequences(dst, tables)
                self.validate(src, dst, tables)
        except MigrationError as exc:
            self.report.result = "FAIL"
            self.report.error = str(exc)
            log(f"ERROR: {exc}")
            return self.finish(started, exc.exit_code)
        except psycopg.OperationalError as exc:
            self.report.result = "FAIL"
            self.report.error = f"connection failed: {exc}"
            log(f"ERROR: {self.report.error}")
            return self.finish(started, EXIT_PREFLIGHT)

        ok = all(t["match"] for t in self.report.tables)
        self.report.result = "PASS" if ok else "FAIL"
        if not ok:
            self.report.error = "row count or checksum mismatch (see tables)"
        return self.finish(started, EXIT_OK if ok else EXIT_MISMATCH)

    def preflight(self, src, dst) -> list[str]:
        with self.phase("preflight"):
            self.report.source = describe(src)
            self.report.target = describe(dst)
            s, t = self.report.source, self.report.target
            log(f"source PostgreSQL {s['server_version']} @ alembic {s['alembic_revision']}")
            log(f"target PostgreSQL {t['server_version']} @ alembic {t['alembic_revision']}")

            if s["major_version"] != t["major_version"]:
                raise MigrationError(
                    f"major version mismatch: {s['major_version']} -> {t['major_version']}",
                    EXIT_PREFLIGHT,
                )
            if t["alembic_revision"] is None:
                raise MigrationError(
                    "target schema not initialised; deploy the app (its init container runs "
                    "migrations) before migrating data",
                    EXIT_PREFLIGHT,
                )
            if s["alembic_revision"] != t["alembic_revision"]:
                raise MigrationError(
                    f"schema revision mismatch: source {s['alembic_revision']} vs target "
                    f"{t['alembic_revision']}; upgrade the older side first",
                    EXIT_PREFLIGHT,
                )

            tables = user_tables(src)
            missing = set(tables) - set(user_tables(dst))
            if missing:
                raise MigrationError(f"tables missing on target: {sorted(missing)}", EXIT_PREFLIGHT)

            if not self.args.validate_only and not self.args.allow_nonempty_target:
                nonempty = [t for t in tables if table_fingerprint(dst, t)[0] > 0]
                if nonempty:
                    raise MigrationError(
                        f"target tables not empty: {nonempty} "
                        "(refusing to merge; use --allow-nonempty-target only if intended)",
                        EXIT_PREFLIGHT,
                    )
            log(f"tables: {', '.join(tables)}")
            return tables

    def copy(self, tables: list[str]) -> None:
        dump_file = self.report_dir / "data.dump"
        with self.phase("dump"):
            run_tool(
                [
                    "pg_dump",
                    "--data-only",
                    "--format=custom",
                    "--no-owner",
                    "--no-privileges",
                    f"--file={dump_file}",
                    *[f"--table=public.{t}" for t in tables],
                ],
                pg_env(self.source_url),
            )
            digest = hashlib.sha256(dump_file.read_bytes()).hexdigest()
            self.report.dump = {"bytes": dump_file.stat().st_size, "sha256": digest}
            log(f"dump {self.report.dump['bytes']} bytes sha256={digest[:16]}...")

        with self.phase("restore"):
            target_env = pg_env(self.target_url)
            run_tool(
                [
                    "pg_restore",
                    "--data-only",
                    "--single-transaction",
                    "--exit-on-error",
                    "--no-owner",
                    "--no-privileges",
                    f"--dbname={target_env['PGDATABASE']}",
                    str(dump_file),
                ],
                target_env,
            )
        if not self.args.keep_dump:
            dump_file.unlink()

    def validate(self, src, dst, tables: list[str]) -> None:
        with self.phase("validate"):
            for table in tables:
                s_rows, s_sum = table_fingerprint(src, table)
                t_rows, t_sum = table_fingerprint(dst, table)
                result = TableResult(table, s_rows, t_rows, s_sum, t_sum)
                self.report.tables.append({**asdict(result), "match": result.match})
                status = "OK " if result.match else "MISMATCH"
                log(
                    f"{status} {table}: rows {s_rows} -> {t_rows}, "
                    f"checksum {s_sum[:12]} -> {t_sum[:12]}"
                )

    def finish(self, started: float, exit_code: int) -> int:
        self.report.duration_seconds = round(time.monotonic() - started, 2)
        self.report_dir.mkdir(parents=True, exist_ok=True)
        (self.report_dir / "report.json").write_text(json.dumps(asdict(self.report), indent=2))
        (self.report_dir / "report.md").write_text(render_markdown(self.report))
        log(f"RESULT {self.report.result} in {self.report.duration_seconds}s -> {self.report_dir}")
        return exit_code


def render_markdown(report: Report) -> str:
    lines = [
        f"# Migration report: **{report.result}**",
        "",
        f"- Started: {report.run_started} (UTC), duration {report.duration_seconds}s, "
        f"mode `{report.mode}`",
        f"- Source: PostgreSQL {report.source.get('server_version', '?')}, "
        f"Alembic `{report.source.get('alembic_revision')}`",
        f"- Target: PostgreSQL {report.target.get('server_version', '?')}, "
        f"Alembic `{report.target.get('alembic_revision')}`",
    ]
    if report.dump:
        lines.append(f"- Dump: {report.dump['bytes']} bytes, sha256 `{report.dump['sha256']}`")
    if report.error:
        lines.append(f"- **Error:** {report.error}")
    if report.tables:
        lines += [
            "",
            "| Table | Source rows | Target rows | Checksum match |",
            "|-------|------------:|------------:|:--------------:|",
        ]
        lines += [
            f"| {t['name']} | {t['source_rows']} | {t['target_rows']} | "
            f"{'yes' if t['match'] else '**NO**'} |"
            for t in report.tables
        ]
    if report.phases:
        lines += ["", "| Phase | Seconds | Status |", "|-------|--------:|--------|"]
        lines += [f"| {p['name']} | {p['seconds']} | {p['status']} |" for p in report.phases]
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--report-dir", type=Path, required=True)
    parser.add_argument("--validate-only", action="store_true", help="compare only; copy nothing")
    parser.add_argument("--allow-nonempty-target", action="store_true")
    parser.add_argument("--keep-dump", action="store_true", help="keep data.dump for audit")
    args = parser.parse_args(argv)

    source_url = os.environ.get("SOURCE_DATABASE_URL")
    target_url = os.environ.get("TARGET_DATABASE_URL")
    if not source_url or not target_url:
        parser.error("SOURCE_DATABASE_URL and TARGET_DATABASE_URL must be set")

    args.report_dir.mkdir(parents=True, exist_ok=True)
    return Migration(source_url, target_url, args.report_dir, args).run()


if __name__ == "__main__":
    sys.exit(main())
