"""Scheduled monitoring: enable, disable and inspect the Hermes cron job that runs scripts/watch.py."""

from __future__ import annotations

import logging
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Mapping

from .. import monitor
from ..errors import InvalidArguments, SysadminError
from ..registry import Op, Param, register

TOOLSET = "monitoring"
JOB_NAME = "hermes-sysadmin-watch"
LAUNCHER = "hermes_sysadmin_watch.py"
STATE_LAUNCHER = "hermes_sysadmin_watch_state.py"  # agent mode: prints the open-alert set, not the delta
AGENT_PROMPT = (
    "hermes-sysadmin monitoring found changes. Use the fleet-health-check skill to triage them "
    "and summarize what needs attention."
)
TIMEOUT = 60
PLUGIN_ROOT = Path(__file__).resolve().parents[2]
_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
_JOB_HEAD = re.compile(r"^\s{2}(\S+)\s+\[([^\]]+)\]\s*$")
_JOB_ROW = re.compile(r"^\s{4}([A-Za-z][A-Za-z ]*?):\s+(.*?)\s*$")
_DELIVER = re.compile(r"[A-Za-z0-9][A-Za-z0-9_:@.#/+\-]*")
log = logging.getLogger(__name__)


def _hermes_home() -> Path:
    try:
        from hermes_constants import get_hermes_home
    except ImportError:
        from hermes_cli.config import get_hermes_home
    return Path(get_hermes_home())


def _hermes_root() -> str | None:
    """The hermes-agent checkout (cwd for `python -m hermes_cli.main`), or None when hermes_cli is not importable."""
    try:
        import hermes_cli
    except ImportError:
        return None
    return str(Path(hermes_cli.__file__).resolve().parent.parent)


def _hermes(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-m", "hermes_cli.main", "cron", *args],
        capture_output=True, text=True, timeout=TIMEOUT, cwd=_hermes_root(),
    )


def _fail(action: str, proc: Any) -> SysadminError:
    detail = (proc.stderr or "").strip() or (proc.stdout or "").strip() or f"exit code {proc.returncode}"
    return SysadminError(f"hermes cron {action} failed: {_ANSI.sub('', detail)[:500]}")


def _launcher_source(*flags: str) -> str:
    lit = repr(str(PLUGIN_ROOT / "scripts" / "watch.py"))
    argv = ", ".join([lit, *map(repr, flags)])
    return f"import runpy, sys; sys.argv=[{argv}]; runpy.run_path({lit}, run_name=\"__main__\")\n"


def parse_jobs(text: str) -> list[dict[str, str]]:
    """Jobs from `hermes cron list` text (the CLI has no JSON output): id, state and each labelled row."""
    jobs: list[dict[str, str]] = []
    for line in _ANSI.sub("", text).splitlines():
        head = _JOB_HEAD.match(line)
        if head:
            jobs.append({"id": head.group(1), "state": head.group(2)})
            continue
        row = _JOB_ROW.match(line)
        if row and jobs:
            jobs[-1].setdefault(row.group(1).strip().lower().replace(" ", "_"), row.group(2))
    return jobs


def _find_jobs() -> list[dict[str, str]]:
    """Every job named JOB_NAME (Hermes allows duplicate names)."""
    proc = _hermes("list", "--all")
    if proc.returncode != 0:
        raise _fail("list", proc)
    return [j for j in parse_jobs(proc.stdout or "") if j.get("name") == JOB_NAME]


def _remove_jobs(jobs: list[dict[str, str]]) -> None:
    for job in jobs:
        proc = _hermes("remove", job["id"])
        if proc.returncode != 0:
            raise _fail("remove", proc)


def _status(service: Any, args: Mapping[str, Any]) -> Any:
    settings = service.settings
    error = None
    try:
        job = next(iter(_find_jobs()), None)
    except Exception as exc:
        job, error = None, str(getattr(exc, "message", exc))
    state = monitor.get_state()
    out = {
        "enabled": bool(job and job.get("state") == "active"),
        "job": job,
        "interval": (job or {}).get("schedule") or f"every {settings.monitor_interval}",
        "deliver": (job or {}).get("deliver"),
        "last_run": state.get("last_run"),
        "open_alerts": state.open(),
        "settings": {
            "alert_disk_free_pct": int(getattr(settings, "alert_disk_free_pct", 10)),
            "alert_patch_age_days": int(getattr(settings, "alert_patch_age_days", 45)),
        },
    }
    if error:
        out["error"] = error
    return out


def _create_args(args: Mapping[str, Any], interval: str) -> list[str]:
    """Arguments after `hermes cron create`: schedule, then flags."""
    mode = args.get("mode") or "watchdog"
    schedule = f"every {interval}"
    if mode == "agent":
        # The optional positional prompt must directly follow the schedule or argparse rejects it.
        return [schedule, AGENT_PROMPT, "--name", JOB_NAME, "--monitor-script", STATE_LAUNCHER, "--deliver", args["deliver"]]
    return [schedule, "--name", JOB_NAME, "--script", LAUNCHER, "--no-agent", "--deliver", args["deliver"]]


def _check(args: Mapping[str, Any]) -> None:
    if not _DELIVER.fullmatch(str(args.get("deliver") or "")):
        raise InvalidArguments("'deliver' must be a Hermes delivery target such as origin, local or telegram.")


def _enable(service: Any, args: Mapping[str, Any]) -> Any:
    _check(args)
    interval = service.settings.monitor_interval
    scripts = _hermes_home() / "scripts"
    scripts.mkdir(parents=True, exist_ok=True)
    (scripts / LAUNCHER).write_text(_launcher_source(), encoding="utf-8")
    (scripts / STATE_LAUNCHER).write_text(_launcher_source("--state"), encoding="utf-8")
    old = _find_jobs()  # ids captured before create so the new job is never removed
    proc = _hermes("create", *_create_args(args, interval))
    if proc.returncode != 0:
        err = _fail("create", proc)
        raise SysadminError(err.message + (" The existing monitoring job was left untouched." if old else ""))
    _remove_jobs(old)
    return {
        "enabled": True, "job": JOB_NAME, "interval": interval, "deliver": args["deliver"],
        "mode": args.get("mode") or "watchdog", "stdout": _ANSI.sub("", proc.stdout or "").strip()[:500],
    }


def _enable_preview(service: Any, args: Mapping[str, Any]) -> Any:
    _check(args)
    interval = service.settings.monitor_interval
    current = _status(service, {})
    return {
        "summary": f"Create Hermes cron job {JOB_NAME} every {interval} delivering to {args['deliver']}",
        "changes": [
            f"write {_hermes_home() / 'scripts' / (STATE_LAUNCHER if args.get('mode') == 'agent' else LAUNCHER)}",
            " ".join(f'"{a}"' if " " in a else a for a in ["hermes", "cron", "create", *_create_args(args, interval)]),
        ],
        "current": current,
    }


def _disable(service: Any, args: Mapping[str, Any]) -> Any:
    jobs = _find_jobs()
    if not jobs:
        return {"enabled": False, "job": None, "removed": False}
    _remove_jobs(jobs)
    return {"enabled": False, "job": JOB_NAME, "removed": True, "count": len(jobs)}


def _disable_preview(service: Any, args: Mapping[str, Any]) -> Any:
    current = _status(service, {})
    job = current["job"]
    return {
        "summary": f"Remove Hermes cron job {JOB_NAME}" if job else f"Hermes cron job {JOB_NAME} is not scheduled; nothing to remove",
        "changes": [f"hermes cron remove {job['id']}"] if job else [],
        "current": current,
    }


register(Op(
    name="monitoring_enable", toolset=TOOLSET, tier="W", script="",
    description=(
        "Turn on scheduled monitoring: create the Hermes cron job that runs the watch script every monitor_interval "
        "and delivers new and resolved findings to the chosen target. Silent when nothing changed."
    ),
    params=(
        Param("deliver", "string", "Hermes delivery target, e.g. origin, local, telegram or platform:chat_id.", required=True),
        Param("mode", "string", "watchdog delivers findings directly; agent has Hermes triage them first.",
              enum=("watchdog", "agent"), default="watchdog"),
    ),
    target=lambda a: f"{JOB_NAME} -> {a.get('deliver', '')}",
    preview=True, local=_enable, local_preview=_enable_preview,
))

register(Op(
    name="monitoring_disable", toolset=TOOLSET, tier="W", script="",
    description="Turn off scheduled monitoring by removing the hermes-sysadmin-watch Hermes cron job.",
    target=lambda a: JOB_NAME,
    preview=True, local=_disable, local_preview=_disable_preview,
))

register(Op(
    name="monitoring_status", toolset=TOOLSET, tier="R", script="",
    description="Whether scheduled monitoring is on, its cron job, interval, delivery target, last run and the open alerts.",
    local=_status,
))
