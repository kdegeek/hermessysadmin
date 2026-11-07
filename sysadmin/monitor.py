"""Scheduled monitoring: pure alert rules, fingerprint-deduped alert state and the run_once driver.

Nothing here raises into cron: run_once swallows every error (a traceback in a cron job becomes a message).
"""

from __future__ import annotations

import json
import logging
import sqlite3
import threading
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping

from . import PLUGIN_ID, fleet

log = logging.getLogger(__name__)
ACTOR = "monitor"
MAX_LINES = 25
PRIVILEGED_GROUPS = ("Domain Admins", "Enterprise Admins", "Schema Admins", "Administrators")
_REQUIRED_SERVICES = ("NTDS", "Netlogon", "KDC")
FLEET_RULES = frozenset({"disk_low", "offline", "patch_age", "reboot_pending", "defender_off"})
ONE_SHOT = frozenset({"privileged_added"})  # reported once; clearing it later is not news


@dataclass(frozen=True)
class Finding:
    rule: str
    host: str
    message: str
    bucket: str = ""

    @property
    def fingerprint(self) -> str:
        return f"{self.rule}:{self.host.lower()}:{self.bucket}"


def _num(value: Any) -> float | None:
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def _items(value: Any) -> list[Mapping[str, Any]]:
    if isinstance(value, Mapping):
        value = value.get("items")
    return [i for i in (value or []) if isinstance(i, Mapping)] if isinstance(value, list) else []


def _fmt(value: float) -> str:
    return str(int(value)) if float(value).is_integer() else f"{value:.1f}"


def _fleet_findings(inputs: Mapping[str, Any], settings: Any, now: datetime) -> list[Finding]:
    out: list[Finding] = []
    prev_online = {str(i.get("name", "")).lower() for i in _items(inputs.get("previous_fleet")) if i.get("online")}
    disk = int(getattr(settings, "alert_disk_free_pct", 10))
    off_days = int(getattr(settings, "alert_offline_days", 7))
    patch_days = int(getattr(settings, "alert_patch_age_days", 45))
    for item in _items(inputs.get("fleet")):
        name = str(item.get("name") or "")
        if not name:
            continue
        pct = _num(item.get("c_free_pct"))
        if item.get("online") and pct is not None and pct < disk:
            gb = _num(item.get("c_free_gb"))
            gb_text = f" ({_fmt(gb)} GB)" if gb is not None else ""
            out.append(Finding("disk_low", name, f"C: {_fmt(pct)}% free{gb_text}", str(int(pct) // 5 * 5)))
        if item.get("online") is False and name.lower() in prev_online:
            seen = fleet.parse_time(item.get("last_logon"))
            if seen is not None and now - seen > timedelta(days=off_days):
                out.append(Finding("offline", name, f"offline; last seen {seen.date().isoformat()}"))
        age = _num(item.get("patch_age_days"))
        if age is not None and age > patch_days:
            out.append(Finding("patch_age", name, f"no update in {int(age)} days", str(int(age) // 30)))
        up = _num(item.get("uptime_days"))
        if item.get("pending_reboot") and up is not None and up > 7:
            out.append(Finding("reboot_pending", name, f"reboot pending, up {int(up)} days"))
        if item.get("defender_rt") is False:
            out.append(Finding("defender_off", name, "Defender real-time protection is off"))
    return out


def _dc_problems(dc: Mapping[str, Any]) -> list[tuple[str, str]]:
    if not dc.get("reachable", True):
        return [("reachable", "domain controller is unreachable")]
    problems: list[tuple[str, str]] = []
    services = dc.get("services") or {}
    for svc in _REQUIRED_SERVICES:
        state = services.get(svc)
        if state is not None and state != "Running":
            problems.append((f"service {svc}", f"{svc} is {state}"))
    for share in ("sysvol", "netlogon"):
        if dc.get(f"{share}_shared") is False:
            problems.append((f"{share} share", f"{share.upper()} share is not published"))
    skew = _num(dc.get("time_skew_seconds"))
    if skew is not None and abs(skew) >= 300:
        problems.append(("time skew", f"clock is {_fmt(skew)}s off"))
    repl = dc.get("replication") or {}
    if _num(repl.get("failures")):
        problems.append(("replication", f"{int(repl['failures'])} replication failure(s)"))
    elif repl.get("error"):
        problems.append(("replication", f"replication check failed: {str(repl['error'])[:120]}"))
    return problems


def evaluate(inputs: Mapping[str, Any], settings: Any, *, now: datetime) -> list[Finding]:
    """Turn gathered inputs into findings. Pure; a missing or malformed key yields no finding."""
    out = _fleet_findings(inputs, settings, now)

    previous = inputs.get("previous_privileged")
    current = inputs.get("privileged") or {}
    if getattr(settings, "alert_privileged_changes", True) and isinstance(previous, Mapping) and isinstance(current, Mapping):
        for group, members in current.items():
            before = {str(m).lower() for m in previous.get(group) or []}
            if group not in previous:
                continue  # a group first seen now (setting changed) gets a baseline, not an alert
            for member in members or []:
                if str(member).lower() not in before:
                    out.append(Finding("privileged_added", str(group), f"{member} added to {group}", str(member)))

    if getattr(settings, "alert_lockouts", True):
        for user in _items(inputs.get("locked")):
            sam = str(user.get("sam") or user.get("name") or "")
            if sam:
                out.append(Finding("locked_out", sam, "account locked out"))

    for gpo in _items(inputs.get("gpo_health")):
        issues = [str(x) for x in gpo.get("health") or []]
        name = str(gpo.get("name") or "")
        if name and issues:
            status = "; ".join(issues)
            out.append(Finding("gpo_problem", name, f"GPO {name}: {status}", status))

    for bk in _items(inputs.get("backups")):
        host = str(bk.get("host") or "")
        if host and (bk.get("stale") is True or bk.get("state") == "bad"):
            out.append(Finding("backup_stale", host, f"backup stale/failed: {bk.get('message') or 'see backup_status'}"))
    errors = inputs.get("backups")
    for err in (errors.get("errors") if isinstance(errors, Mapping) else None) or []:
        host = str(err.get("host") or "") if isinstance(err, Mapping) else ""
        if host:
            out.append(Finding("backup_stale", host, f"unreachable: {str(err.get('message') or 'no answer')[:160]}", "unreachable"))

    for dc in _items(inputs.get("dc_health")):
        name = str(dc.get("name") or dc.get("hostname") or "")
        status = dc.get("status")
        if not name or status not in ("bad", "warn"):
            continue
        problems = _dc_problems(dc)
        if status == "warn":  # warnings are silent except replication
            problems = [p for p in problems if p[0] == "replication"]
        elif not problems:
            problems = [("status", "reported bad")]
        for check, detail in problems:
            out.append(Finding("dc_health", name, f"{check}: {detail}", check))
    return out


class AlertState:
    def __init__(self, conn: sqlite3.Connection) -> None:
        self._conn = conn
        self._lock = threading.Lock()
        with self._lock:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS alerts (fingerprint TEXT PRIMARY KEY, rule TEXT, host TEXT, message TEXT, "
                "first_seen TEXT, last_seen TEXT, active INTEGER)"
            )
            conn.execute("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)")
            conn.commit()

    def diff(
        self, findings: list[Finding], *, now: datetime, scope: set[str] | frozenset[str] | None = None,
    ) -> tuple[list[Finding], list[dict[str, Any]]]:
        """Upsert active findings; resolve active alerts that are gone. `scope` limits resolution to those rules
        (a source that could not be read must not resolve its alerts)."""
        stamp = now.isoformat()
        seen = {f.fingerprint: f for f in findings}
        new: list[Finding] = []
        resolved: list[dict[str, Any]] = []
        with self._lock:
            active = {r[0]: r for r in self._conn.execute(
                "SELECT fingerprint, rule, host, message, first_seen FROM alerts WHERE active = 1")}
            for fp, f in seen.items():
                if fp in active:
                    self._conn.execute("UPDATE alerts SET last_seen = ? WHERE fingerprint = ?", (stamp, fp))
                else:
                    new.append(f)
                    self._conn.execute(
                        "INSERT INTO alerts (fingerprint, rule, host, message, first_seen, last_seen, active) VALUES (?,?,?,?,?,?,1) "
                        "ON CONFLICT(fingerprint) DO UPDATE SET rule=excluded.rule, host=excluded.host, message=excluded.message, "
                        "first_seen=excluded.first_seen, last_seen=excluded.last_seen, active=1",
                        (fp, f.rule, f.host, f.message, stamp, stamp),
                    )
            for fp, row in active.items():
                if fp not in seen and (scope is None or row[1] in scope):
                    if row[1] not in ONE_SHOT:
                        resolved.append({"fingerprint": fp, "rule": row[1], "host": row[2], "message": row[3], "first_seen": row[4]})
                    self._conn.execute("UPDATE alerts SET active = 0, last_seen = ? WHERE fingerprint = ?", (stamp, fp))
            self._conn.commit()
        return new, resolved

    def open(self) -> list[dict[str, Any]]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT fingerprint, rule, host, message, first_seen, last_seen FROM alerts WHERE active = 1 ORDER BY first_seen, fingerprint"
            ).fetchall()
        return [dict(zip(("fingerprint", "rule", "host", "message", "first_seen", "last_seen"), r)) for r in rows]

    def get(self, key: str) -> str | None:
        with self._lock:
            row = self._conn.execute("SELECT value FROM kv WHERE key = ?", (key,)).fetchone()
        return row[0] if row else None

    def put(self, key: str, value: str) -> None:
        with self._lock:
            self._conn.execute("INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", (key, value))
            self._conn.commit()


_state: AlertState | None = None
_state_lock = threading.Lock()


def get_state() -> AlertState:
    global _state
    with _state_lock:
        if _state is None:
            try:
                from plugins.plugin_storage import plugin_db
                _state = AlertState(plugin_db(PLUGIN_ID, "monitor.db"))
            except ImportError:
                log.warning("hermes-sysadmin monitor: plugin_storage unavailable; alert state is in memory only")
                _state = AlertState(sqlite3.connect(":memory:", check_same_thread=False))
        return _state


def set_state(state: AlertState | None) -> None:
    global _state
    with _state_lock:
        _state = state


def render(new: list[Finding], resolved: list[dict[str, Any]]) -> str:
    if not new and not resolved:
        return ""
    lines = [f"**hermes-sysadmin**: {len(new)} new, {len(resolved)} resolved"]
    lines += [f"- 🔴 {f.host}: {f.message}" for f in new[:MAX_LINES]]
    if len(new) > MAX_LINES:
        lines.append(f"- … and {len(new) - MAX_LINES} more")
    lines += [f"- ✅ resolved: {r['host']}: {r['message']}" for r in resolved[:MAX_LINES]]
    if len(resolved) > MAX_LINES:
        lines.append(f"- … and {len(resolved) - MAX_LINES} more resolved")
    return "\n".join(lines)


def render_open(alerts: list[dict[str, Any]]) -> str:
    """Stable rendering of the open alerts (no timestamps), for agent mode where a change of output wakes the agent."""
    if not alerts:
        return ""
    lines = sorted(f"- {a['host']}: {a['message']}" for a in alerts)
    shown = lines[:MAX_LINES] + ([f"- … and {len(lines) - MAX_LINES} more"] if len(lines) > MAX_LINES else [])
    return "\n".join([f"**hermes-sysadmin**: {len(lines)} open alert{'s' if len(lines) != 1 else ''}", *shown])


def _call(service: Any, op: str, args: dict[str, Any]) -> Any:
    """Data from a successful call, else None. Never raises."""
    try:
        res = service.call(op, args, actor=ACTOR)
    except Exception:
        log.exception("hermes-sysadmin monitor: %s failed", op)
        return None
    if not isinstance(res, Mapping) or not res.get("ok"):
        return None
    return res.get("data")


def _members(group: Mapping[str, Any]) -> list[str]:
    return [str(m.get("sam") or m.get("name")) for m in group.get("members") or [] if isinstance(m, Mapping) and (m.get("sam") or m.get("name"))]


def _privileged_names(settings: Any) -> list[str]:
    names = list(PRIVILEGED_GROUPS)
    for extra in getattr(settings, "privileged_groups", ()) or ():
        if extra.lower() not in {n.lower() for n in names}:
            names.append(extra)
    return names


_SOURCE_RULES = {
    "fleet": FLEET_RULES, "locked": {"locked_out"}, "privileged": {"privileged_added"},
    "gpo_health": {"gpo_problem"}, "backups": {"backup_stale"}, "dc_health": {"dc_health"},
}


def _scope(inputs: Mapping[str, Any]) -> set[str]:
    return {rule for key, rules in _SOURCE_RULES.items() if key in inputs for rule in rules}


def _gather(service: Any, settings: Any, state: AlertState) -> tuple[dict[str, Any], str | None]:
    """Inputs for evaluate plus the privileged baseline to store once the run has succeeded."""
    inputs: dict[str, Any] = {}
    baseline: str | None = None
    inv = _call(service, "fleet_inventory", {"refresh": True, "kind": "any"})
    if isinstance(inv, Mapping):
        inputs["fleet"] = inv
        try:
            prev = fleet.get_store().previous(kind="any")  # same kind the monitor records below
            items = list((prev or {}).get("items") or [])
            # A host with an open offline alert still counts as "was online", or the alert would resolve next run.
            items += [{"name": a["host"], "online": True} for a in state.open() if a["rule"] == "offline"]
            inputs["previous_fleet"] = items
        except Exception:
            log.exception("hermes-sysadmin monitor: previous snapshot unavailable")
            inputs["previous_fleet"] = []
    if getattr(settings, "alert_lockouts", True):
        locked = _call(service, "ad_user_list", {"status": "locked", "limit": 500})
        if locked is not None:
            inputs["locked"] = _items(locked)
    if getattr(settings, "alert_privileged_changes", True):
        current: dict[str, list[str]] = {}
        for name in _privileged_names(settings):
            group = _call(service, "ad_group_get", {"identity": name, "limit": 1000})
            if isinstance(group, Mapping):
                current[name] = _members(group)
        stored = state.get("privileged")
        try:
            previous = json.loads(stored) if stored else None
        except ValueError:
            previous = None
        if current:
            inputs["privileged"] = current
            inputs["previous_privileged"] = previous if isinstance(previous, dict) else None
            merged = dict(previous) if isinstance(previous, dict) else {}
            merged.update(current)  # groups that failed to read keep their old baseline
            baseline = json.dumps(merged)
    for key, op in (("gpo_health", "gpo_health"), ("backups", "backup_status"), ("dc_health", "ad_dc_health")):
        data = _call(service, op, {})
        if data is not None:
            inputs[key] = data
    return inputs, baseline


def run_once(service: Any, settings: Any, *, now: datetime | None = None) -> str:
    """One monitoring pass. Returns the message to deliver, or "" when nothing changed. Never raises."""
    try:
        now = now or datetime.now(timezone.utc)
        state = get_state()
        inputs, baseline = _gather(service, settings, state)
        findings = evaluate(inputs, settings, now=now)
        new, resolved = state.diff(findings, now=now, scope=_scope(inputs))
        if baseline is not None:  # only after diff succeeded, or a failed run would swallow the addition
            state.put("privileged", baseline)
        state.put("last_run", now.isoformat())
        return render(new, resolved)
    except Exception:
        log.exception("hermes-sysadmin monitor: run failed")
        return ""
