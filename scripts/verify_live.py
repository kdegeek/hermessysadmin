"""Read-only live verification against the configured domain.

Runs inside the Hermes Python environment (it reads the plugin's real settings and
secret the same way the plugin does). Safety:

- the Service is built with mode forced to "read-only", so policy blocks every write;
- only read-tier (R) operations are called with Service.call();
- a few write operations are exercised with Service.preview() only: the script runs
  with -Preview and returns its planned changes before touching anything.

Each call is reported as OK, SKIP (a Gallery module or server role is not installed, or the
script has no safe sample parameters) or ERR. The exit code is non-zero only when there is an ERR.

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

from sysadmin import catalog, ops  # noqa: E402,F401
from sysadmin.audit import AuditLog  # noqa: E402
from sysadmin.config import load_settings  # noqa: E402
from sysadmin.registry import OPS  # noqa: E402
from sysadmin.runner import Runner  # noqa: E402
from sysadmin.runtime import make_transport  # noqa: E402
from sysadmin.service import Service  # noqa: E402


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


def catalog_sample_params(op, ctx):
    """Safe sample parameters for a read catalog entry, or None when a required one has no sample.

    ctx holds dc, domain and ws (the first online workstation, or None). Entries that need
    a parameter we cannot fill safely are skipped by the caller as NoSample, never guessed.
    """
    meta_id = op.meta["id"]
    base = {"computers": [ctx["ws"]]} if op.meta["target"] == "endpoint" else {}
    # files.* entries take a file server and a local path on it (Get-Acl runs there); the DC's SYSVOL always exists.
    file_sample = {"Server": ctx["dc"], "Path": "C:\\Windows\\SYSVOL"}
    samples = {
        "network.test_port": {"Target": ctx["dc"], "Port": 389},
        "events.search": {"Log": "System", "Id": 6005},
        "dns.stale_records": {"Zone": ctx["domain"]},
        "dhcp.leases_for_host": {"Name": (ctx["ws"] or "").split(".")[0]},
        "files.ntfs_access": file_sample,
        "files.ntfs_inheritance": file_sample,
        "files.ntfs_orphaned_sids": file_sample,
        "files.broad_write_access": file_sample,
        "files.largest_files": file_sample,
        "files.owner_report": file_sample,
        "files.recent_files": file_sample,
        "files.share_permissions": {"Server": ctx["dc"]},
        # Harmless lookups: a MAC that matches nothing, the DC's own name, a built-in account.
        "dhcp.lease_for_mac": {"Mac": "00-00-5E-00-53-00"},
        "dns.find_records": {"Name": (ctx["dc"] or "").split(".")[0]},
        "network.dns_resolve": {"Name": ctx["dc"]},
        "network.traceroute": {"Target": ctx["dc"]},
        "gpo.settings_search": {"Keyword": "Audit"},
        "sessions.find_user": {"User": "Administrator"},
        "sessions.user_groups": {"Identity": "Administrator"},
        "sessions.user_last_logon": {"Identity": "Administrator"},
    }
    extra = samples.get(meta_id, {})
    params = {**base, **extra}
    if any(v in (None, "") for v in params.values()):
        return None
    if any(p.required and p.name not in params for p in op.params):
        return None
    return params


#: Catalog writes previewed (-Preview only: the script reads current state and returns its plan) on the
#: first online workstation, with harmless sample arguments. Entries that need a specific printer, OU or
#: session are not previewed here.
ENDPOINT_WRITE_PREVIEWS = {
    "cat.remote.set_nla": {"Required": True},
    "cat.remote.restart_computer": {"Reason": "verify"},
    "cat.remote.enable_rdp": {},
    "cat.remote.enable_remote_assistance": {},
    "cat.remote.open_rdp_firewall": {},
    "cat.remote.set_shadow_policy": {},
    "cat.remote.lock_workstation": {},
    "cat.remote.send_message": {"Message": "verify"},
    "cat.maint.gpupdate": {},
    "cat.maint.clear_temp": {},
    "cat.maint.flush_dns": {},
    "cat.maint.restart_service": {"Name": "Spooler"},
    "cat.maint.time_resync": {},
    "cat.maint.set_service_startup": {"Name": "Spooler", "StartupType": "Automatic"},
    "cat.maint.stop_process": {"Name": "notepad"},
    "cat.maint.empty_recycle_bin": {},
    "cat.maint.clear_wu_cache": {},
    "cat.maint.remove_stale_profiles": {"MinDaysUnused": 365},
    "cat.network.register_dns": {},
    "cat.network.dhcp_renew": {},
    "cat.patch.trigger_scan": {},
    "cat.patch.wu_install": {},
    "cat.printers.restart_spooler": {},
    "cat.security.defender_quick_scan": {},
    "cat.security.defender_update_signatures": {},
    "cat.security.disable_llmnr": {},
    "cat.security.disable_smb1_server": {},
    "cat.security.enable_firewall_profiles": {},
}


def first_online_workstation(inventory):
    items = (inventory or {}).get("items") or []
    return next((i.get("name") for i in items if i.get("online") and i.get("name")), None)


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
    # Optional overrides for testing each transport without editing config.yaml.
    for flag, field, choices in (("--transport", "transport", ("local", "winrm")), ("--run-as", "run_as", ("account", "hermes_user"))):
        if flag in argv:
            value = argv[argv.index(flag) + 1]
            if value not in choices:
                print(f"{flag} must be one of {', '.join(choices)}")
                return 2
            base = replace(base, **{field: value})
    if not base.configured:
        print(f"Plugin is not configured for transport={base.transport} run_as={base.run_as} "
              "(winrm needs host/username/password; local+account needs username/password).")
        return 2
    settings = replace(base, mode="read-only")
    # Same transport selection as the plugin runtime (local PowerShell or WinRM jump host).
    transport = make_transport(settings)
    if settings.transport == "local":
        who = settings.username if settings.run_as == "account" else "the Hermes user"
        print(f"transport=local run_as={settings.run_as} ({who})")
    else:
        print(f"transport=winrm run_as=- (jump host {settings.host} as {settings.username})")
    audit = AuditLog(sqlite3.connect(":memory:", check_same_thread=False))  # never touch the real audit log
    svc = Service(settings, Runner(transport), audit)
    if "--only" in argv:
        # Debug one read op and print its whole envelope: --only <op> [--args '<json>'].
        name = argv[argv.index("--only") + 1]
        if name not in OPS or OPS[name].tier != "R":
            print(f"--only takes a read op; {name} is not one")
            return 2
        args = json.loads(argv[argv.index("--args") + 1]) if "--args" in argv else {}
        print(json.dumps(svc.call(name, args, actor="command"), indent=1, default=str)[:20000])
        return 0
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
            row["status"] = "OK"
            row["shape"] = shape(res.get("data"))
        else:
            row["error"] = res.get("error")
            # A Gallery module or server role that is not installed is an environment fact, not a failure.
            row["status"] = "SKIP" if (row["error"] or {}).get("type") == "NotInstalled" else "ERR"
        results.append(row)
        detail = row.get("shape") if res.get("ok") else f"{row['error'].get('type')}: {row['error'].get('message')}"
        flag = {"OK": "OK  ", "SKIP": "SKIP", "ERR": "ERR "}[row["status"]]
        print(f"{flag} {dt:6.1f}s {'P' if preview else 'R'} {name} {json.dumps(args or {})[:60]} -> {json.dumps(detail, default=str)[:400]}")
        return res.get("data") if res.get("ok") else None

    def skip(name, args, reason):
        results.append({"op": name, "mode": "read", "args": args, "ok": None, "status": "SKIP", "seconds": 0,
                        "error": {"type": reason, "message": "not run"}})
        print(f"SKIP    0.0s R {name} {json.dumps(args)[:60]} -> {reason}")

    conn = run("ad_connection_test") or {}
    if conn:
        print(f"     local identity {conn.get('local_identity') or conn.get('identity')}; network identity "
              f"{conn.get('network_identity') or conn.get('network_identity_error')}")
    dcs = run("ad_dc_list") or {}
    dc = next((d.get("name") for d in dcs.get("items", []) if d.get("name")), settings.host or None) or ""
    run("ad_dc_health")
    run("ad_domain_overview")
    users = run("ad_user_list", {"limit": 25}) or {}
    for filt in ({"status": "locked"}, {"status": "disabled"}, {"stale_days": 90}, {"password": "expiring"},
                 {"password": "never_expires"}):
        run("ad_user_list", {**filt, "limit": 10})
    run("ad_user_list", {"privileged": True, "limit": 25})
    who = settings.username or conn.get("network_identity") or conn.get("identity") or ""
    me = who.split("\\")[-1].split("@")[0]
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

    # v0.2: fleet, remote access, monitoring and the read-tier catalog.
    inventory = run("fleet_inventory") or {}
    ws = first_online_workstation(inventory)
    run("fleet_history", {"days": 30})
    run("catalog_module_status")
    run("monitoring_status")
    if ws:
        run("fleet_device", {"computer": ws})
        run("remote_sessions", {"computers": [ws]})
        run("remote_access_check", {"computer": ws})
    else:
        for name in ("fleet_device", "remote_sessions", "remote_access_check"):
            skip(name, {}, "NoOnlineWorkstation")
    domain = dc.split(".", 1)[1] if "." in dc else (settings.host.split(".", 1)[1] if "." in settings.host else None)
    ctx = {"dc": dc, "domain": domain, "ws": ws}
    for entry in catalog.entries():
        if entry.tier != "R":
            continue
        if entry.meta["target"] == "endpoint" and not ws:
            skip(entry.name, {}, "NoOnlineWorkstation")
            continue
        params = catalog_sample_params(entry, ctx)
        if params is None:
            skip(entry.name, {}, "NoSample")
            continue
        run(entry.name, params)

    # Previews: each script returns its plan before any change.
    run("ad_group_add_member", {"group": "Domain Users", "members": [me]}, preview=True)
    run("rdp_set_enabled", {"hosts": [dc], "enabled": True}, preview=True)
    run("ad_user_unlock", {"identity": me}, preview=True)
    if ws:
        for name, extra in ENDPOINT_WRITE_PREVIEWS.items():
            run(name, {"computers": [ws], **extra}, preview=True)
        run("cat.ad.disable_stale_computers", {"Names": [ws.split(".")[0]]}, preview=True)
    run("cat.ad.protect_ous", {"All": True}, preview=True)
    run("cat.dns.clear_server_cache", {"Server": dc}, preview=True)
    run("monitoring_enable", {"deliver": "origin"}, preview=True)
    transport.close()

    counts = {k: sum(1 for r in results if r["status"] == k) for k in ("OK", "SKIP", "ERR")}
    print(f"\n{counts['OK']} OK / {counts['SKIP']} SKIP / {counts['ERR']} ERR of {len(results)}; sample user from list: {sample}")
    if out_path:
        Path(out_path).write_text(json.dumps(results, indent=2, default=str), encoding="utf-8")
    return 1 if counts["ERR"] else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
