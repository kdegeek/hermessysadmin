"""Fleet snapshot store and summary helpers (no WinRM here; the scripts gather, this file stores and counts)."""

from __future__ import annotations

import json
import logging
import re
import sqlite3
import threading
from datetime import datetime, timedelta, timezone
from typing import Any, Iterable, Mapping

log = logging.getLogger(__name__)
PLUGIN_ID = "hermes-sysadmin"
PATCH_COMPLIANT_DAYS = 35
_FRACTION = re.compile(r"(\.\d{6})\d+")


def parse_time(value: Any) -> datetime | None:
    """Parse an ISO-8601 timestamp (PowerShell 'o' format included) to an aware UTC datetime."""
    if not value:
        return None
    text = _FRACTION.sub(r"\1", str(value).strip())
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _patch_bucket(days: Any) -> str:
    if not isinstance(days, (int, float)) or isinstance(days, bool):
        return "unknown"
    if days < 7:
        return "<7"
    if days <= 35:
        return "7-35"
    if days <= 90:
        return "35-90"
    return ">90"


def _seen_bucket(last_logon: Any, now: datetime) -> str:
    seen = parse_time(last_logon)
    if seen is None:
        return "never"
    days = (now - seen).total_seconds() / 86400
    if days < 1:
        return "<1d"
    if days < 7:
        return "1-7d"
    if days < 30:
        return "7-30d"
    if days < 90:
        return "30-90d"
    return ">90d"


def summarize(items: Iterable[Mapping[str, Any]], *, now: datetime, disk_pct: int) -> dict[str, Any]:
    rows = list(items)
    online = [i for i in rows if i.get("online")]
    patch = {"<7": 0, "7-35": 0, "35-90": 0, ">90": 0, "unknown": 0}
    seen = {"<1d": 0, "1-7d": 0, "7-30d": 0, "30-90d": 0, ">90d": 0, "never": 0}
    os_mix: dict[str, int] = {}
    for i in rows:
        patch[_patch_bucket(i.get("patch_age_days"))] += 1
        seen[_seen_bucket(i.get("last_logon"), now)] += 1
        name = str(i.get("os") or "Unknown")
        os_mix[name] = os_mix.get(name, 0) + 1

    def num(i: Mapping[str, Any], key: str) -> float | None:
        v = i.get(key)
        return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None

    return {
        "total": len(rows),
        "online": len(online),
        "offline": len(rows) - len(online),
        "pending_reboot": sum(1 for i in rows if i.get("pending_reboot")),
        "low_disk": sum(1 for i in online if num(i, "c_free_pct") is not None and num(i, "c_free_pct") < disk_pct),
        "defender_off": sum(1 for i in rows if i.get("defender_rt") is False),
        "bitlocker_off": sum(1 for i in rows if i.get("bitlocker") not in ("on", None)),
        "rdp_no_nla": sum(1 for i in rows if i.get("rdp") and i.get("nla") is False),
        "patch_compliant": sum(
            1 for i in online if num(i, "patch_age_days") is not None and num(i, "patch_age_days") <= PATCH_COMPLIANT_DAYS
        ),
        "os_mix": os_mix,
        "patch_age_buckets": patch,
        "last_seen_buckets": seen,
    }


class FleetStore:
    def __init__(self, conn: sqlite3.Connection) -> None:
        self._conn = conn
        self._lock = threading.Lock()
        with self._lock:
            self._conn.execute("CREATE TABLE IF NOT EXISTS snapshots (taken_at TEXT PRIMARY KEY, summary TEXT, items TEXT)")
            self._conn.commit()

    def record(self, snapshot: Mapping[str, Any]) -> bool:
        with self._lock:
            cur = self._conn.execute(
                "INSERT OR IGNORE INTO snapshots (taken_at, summary, items) VALUES (?, ?, ?)",
                (str(snapshot["taken_at"]), json.dumps(snapshot.get("summary") or {}, default=str),
                 json.dumps(snapshot.get("items") or [], default=str)),
            )
            self._conn.commit()
            return cur.rowcount == 1

    def _ordered(self) -> list[tuple[datetime, str]]:
        """(time, taken_at key) for every snapshot, oldest first. Keys that do not parse sort first."""
        with self._lock:
            keys = [r[0] for r in self._conn.execute("SELECT taken_at FROM snapshots")]
        floor = datetime.min.replace(tzinfo=timezone.utc)
        return sorted(((parse_time(k) or floor, k) for k in keys), key=lambda p: p[0])

    def _load(self, key: str) -> dict[str, Any] | None:
        with self._lock:
            row = self._conn.execute("SELECT taken_at, summary, items FROM snapshots WHERE taken_at = ?", (key,)).fetchone()
        if row is None:
            return None
        return {"taken_at": row[0], "summary": json.loads(row[1] or "{}"), "items": json.loads(row[2] or "[]")}

    def latest(self) -> dict[str, Any] | None:
        order = self._ordered()
        return self._load(order[-1][1]) if order else None

    def previous(self) -> dict[str, Any] | None:
        order = self._ordered()
        return self._load(order[-2][1]) if len(order) > 1 else None

    def history(self, days: int, now: datetime | None = None) -> list[dict[str, Any]]:
        cutoff = (now or datetime.now(timezone.utc)) - timedelta(days=days)
        keys = [k for t, k in self._ordered() if t >= cutoff]
        if not keys:
            return []
        with self._lock:
            rows = {r[0]: r[1] for r in self._conn.execute(
                f"SELECT taken_at, summary FROM snapshots WHERE taken_at IN ({','.join('?' * len(keys))})", keys)}
        return [{"taken_at": k, "summary": json.loads(rows[k] or "{}")} for k in keys if k in rows]

    def prune(self, days: int = 90, now: datetime | None = None) -> int:
        cutoff = (now or datetime.now(timezone.utc)) - timedelta(days=days)
        stale = [k for t, k in self._ordered() if t < cutoff]
        if not stale:
            return 0
        with self._lock:
            cur = self._conn.executemany("DELETE FROM snapshots WHERE taken_at = ?", [(k,) for k in stale])
            self._conn.commit()
            return cur.rowcount


_store: FleetStore | None = None
_store_lock = threading.Lock()


def _open() -> FleetStore:
    try:
        from plugins.plugin_storage import plugin_db
    except ImportError:
        return FleetStore(sqlite3.connect(":memory:", check_same_thread=False))
    return FleetStore(plugin_db(PLUGIN_ID, "fleet.db"))


def get_store() -> FleetStore:
    global _store
    with _store_lock:
        if _store is None:
            _store = _open()
        return _store


def set_store(store: FleetStore | None) -> None:
    global _store
    with _store_lock:
        _store = store
