"""Read-only live verification against the configured domain.

Runs inside the Hermes Python environment (it reads the plugin's real settings and
secret the same way the plugin does). Safety:

- the Service is built with mode forced to "read-only", so policy blocks every write;
- only read-tier (R) operations are called with Service.call();
- a few write operations are exercised with Service.preview() only: the script runs
  with -Preview and returns its planned changes before touching anything.

Usage (on the Hermes host, from the hermes-agent directory):
    <hermes venv python> <plugin>/scripts/verify_live.py [--out report.json]
"""

from __future__ import annotations

import json
import sqlite3
import sys
import time
from dataclasses import replace
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from sysadmin import ops  # noqa: E402,F401
from sysadmin.audit import AuditLog  # noqa: E402
from sysadmin.config import load_settings  # noqa: E402
from sysadmin.registry import OPS  # noqa: E402
from sysadmin.runner import Runner, load_prelude  # noqa: E402
from sysadmin.service import Service  # noqa: E402
from sysadmin.transport import PsrpTransport  # noqa: E402


def shape(data):
    """A compact description of a result: counts and keys, not the full payload."""
    if isinstance(data, dict):
        out = {}
        for k, v in list(data.items())[:14]:
            if isinstance(v, list):
                out[k] = f"[{len(v)}]"
            elif isinstance(v, dict):
                out[k] = "{" + ",".join(list(v)[:8]) + "}"
            else:
                text = str(v)
                out[k] = text if len(text) <= 60 else text[:57] + "..."
        return out
    if isinstance(data, list):
        return f"[{len(data)}]"
    return str(data)[:80]


def _load_hermes_env() -> None:
    """Outside the gateway nothing has loaded Hermes's .env yet; use Hermes's own loader."""
    try:
        from hermes_cli.env_loader import load_hermes_dotenv
    except ImportError:
        return
    load_hermes_dotenv()


def main(argv):
    _load_hermes_env()
    out_path = argv[argv.index("--out") + 1] if "--out" in argv else None
    base = load_settings()
    if not base.configured:
        print("Plugin is not configured (host/username/password missing in this process).")
        return 2
    settings = replace(base, mode="read-only")
    transport = PsrpTransport(settings, load_prelude())
    audit = AuditLog(sqlite3.connect(":memory:", check_same_thread=False))  # never touch the real audit log
    svc = Service(settings, Runner(transport), audit)
    results = []

    def run(name, args=None, preview=False):
        op = OPS[name]
        if not preview and op.tier != "R":
            raise SystemExit(f"refusing to call non-read op {name}")
        t0 = time.monotonic()
        if preview:
            res = Service(replace(base, mode="strict"), Runner(transport), audit).preview(name, args or {})
        else:
            res = svc.call(name, args or {}, actor="command")
        dt = time.monotonic() - t0
        row = {"op": name, "mode": "preview" if preview else "read", "args": args or {}, "ok": res.get("ok"),
               "seconds": round(dt, 2)}
        if res.get("ok"):
            row["shape"] = shape(res.get("data"))
        else:
            row["error"] = res.get("error")
        results.append(row)
        flag = "OK " if res.get("ok") else "ERR"
        detail = row.get("shape") if res.get("ok") else f"{row['error'].get('type')}: {row['error'].get('message')}"
        print(f"{flag} {dt:6.1f}s {'P' if preview else 'R'} {name} {json.dumps(args or {})[:60]} -> {json.dumps(detail, default=str)[:400]}")
        return res.get("data") if res.get("ok") else None

    run("ad_connection_test")
    dcs = run("ad_dc_list") or {}
    dc = next((d.get("name") for d in dcs.get("items", []) if d.get("name")), settings.host)
    run("ad_dc_health")
    run("ad_domain_overview")
    users = run("ad_user_list", {"limit": 25}) or {}
    for filt in ({"status": "locked"}, {"status": "disabled"}, {"stale_days": 90}, {"password": "expiring"},
                 {"password": "never_expires"}):
        run("ad_user_list", {**filt, "limit": 10})
    run("ad_user_list", {"privileged": True, "limit": 25})
    me = settings.username.split("\\")[-1].split("@")[0]
    run("ad_search", {"query": me, "limit": 5})
    sample = next((u.get("sam") or u.get("samAccountName") or u.get("name") for u in users.get("items", [])), me)
    run("ad_user_get", {"identity": me})
    run("ad_lockout_source", {"identity": me, "hours": 24})
    run("ad_group_list", {"limit": 25})
    run("ad_group_get", {"identity": "Domain Admins", "limit": 50})
    run("ad_recycle_bin_list", {"limit": 10})
    gpos = run("gpo_list") or {}
    run("gpo_health")
    first_gpo = next((g.get("name") for g in gpos.get("items", []) if g.get("name")), None)
    if first_gpo:
        run("gpo_get", {"identity": first_gpo})
        run("gpo_backups", {"identity": first_gpo})
    run("gpo_backups")
    run("rdp_host_status", {"hosts": [dc]})
    run("rdp_sessions", {"hosts": [dc]})
    run("rdp_connect_file", {"host": dc})
    run("backup_status", {"hosts": [dc]})
    run("backup_versions", {"host": dc})
    run("backup_jobs", {"host": dc})
    run("sysadmin_audit_log", {"limit": 5})
    # Previews: each script returns its plan before any change.
    run("ad_group_add_member", {"group": "Domain Users", "members": [me]}, preview=True)
    run("rdp_set_enabled", {"hosts": [dc], "enabled": True}, preview=True)
    run("ad_user_unlock", {"identity": me}, preview=True)
    transport.close()

    ok = sum(1 for r in results if r["ok"])
    print(f"\n{ok}/{len(results)} passed; sample user from list: {sample}")
    if out_path:
        Path(out_path).write_text(json.dumps(results, indent=2, default=str), encoding="utf-8")
    return 0 if ok == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
