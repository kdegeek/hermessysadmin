"""Local SQLite audit log of every write attempt (allowed, approved, denied, blocked or failed)."""

from __future__ import annotations

import json
import sqlite3
import threading
from datetime import datetime, timezone
from typing import Any, Mapping

from . import PLUGIN_ID

_COLUMNS = ("id", "ts", "actor", "session", "tool", "target", "tier", "decision", "result", "params")
_SCHEMA = """
CREATE TABLE IF NOT EXISTS audit (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    actor TEXT NOT NULL,
    session TEXT NOT NULL DEFAULT '',
    tool TEXT NOT NULL,
    target TEXT NOT NULL DEFAULT '',
    tier TEXT NOT NULL,
    decision TEXT NOT NULL,
    result TEXT NOT NULL,
    params TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS audit_ts ON audit(ts);
"""


_SECRET_NAMES = frozenset({
    "password", "newpassword", "oldpassword", "currentpassword",
    "passwd", "pwd", "securepassword", "secret",
})


def _is_secret_key(key: Any) -> bool:
    norm = str(key).lower().replace("_", "").replace("-", "")
    return norm in _SECRET_NAMES or norm.endswith("password")


def _redact_value(value: Any) -> Any:
    if isinstance(value, Mapping):
        return {(k if isinstance(k, str) else str(k)): ("[redacted]" if _is_secret_key(k) else _redact_value(v)) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_redact_value(v) for v in value]
    return value


def redact(args: Mapping[str, Any] | None) -> dict[str, Any]:
    return _redact_value(args or {})


MAX_PARAMS_JSON = 4000


def _params_json(params: Mapping[str, Any] | None) -> str:
    """Redacted params as JSON, kept valid when it exceeds MAX_PARAMS_JSON."""
    text = json.dumps(redact(params), default=str)
    if len(text) <= MAX_PARAMS_JSON:
        return text
    return json.dumps({"_truncated": text[: MAX_PARAMS_JSON - 100]})


class AuditLog:
    def __init__(self, conn: sqlite3.Connection) -> None:
        self._conn = conn
        self._lock = threading.Lock()
        with self._lock:
            conn.executescript(_SCHEMA)
            conn.commit()

    def record(
        self, *, actor: str, session: str, tool: str, target: str, tier: str,
        decision: str, result: str, params: Mapping[str, Any],
    ) -> None:
        row = (
            datetime.now(timezone.utc).isoformat(timespec="seconds"),
            actor,
            session or "",
            tool,
            target or "",
            tier,
            decision,
            str(result)[:500],
            _params_json(params),
        )
        with self._lock:
            self._conn.execute(
                "INSERT INTO audit (ts, actor, session, tool, target, tier, decision, result, params) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                row,
            )
            self._conn.commit()

    def query(self, *, limit: int = 100, actor: str | None = None, decision: str | None = None) -> list[dict[str, Any]]:
        sql = f"SELECT {', '.join(_COLUMNS)} FROM audit"
        where: list[str] = []
        values: list[Any] = []
        if actor:
            where.append("actor = ?")
            values.append(actor)
        if decision:
            where.append("decision LIKE ?")
            values.append(f"{decision}%")
        if where:
            sql += " WHERE " + " AND ".join(where)
        sql += " ORDER BY id DESC LIMIT ?"
        values.append(max(1, min(int(limit), 1000)))
        with self._lock:
            rows = self._conn.execute(sql, values).fetchall()
        out = []
        for row in rows:
            item = dict(zip(_COLUMNS, row))
            item["params"] = json.loads(item["params"] or "{}")
            out.append(item)
        return out


def open_audit() -> AuditLog:
    try:
        from plugins.plugin_storage import plugin_db
    except ImportError:
        return AuditLog(sqlite3.connect(":memory:", check_same_thread=False))
    return AuditLog(plugin_db(PLUGIN_ID, "audit.db"))
