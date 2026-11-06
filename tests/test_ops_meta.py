from dataclasses import replace

from sysadmin import ops  # noqa: F401
from sysadmin.config import Settings
from sysadmin.policy import decide
from sysadmin.registry import OPS

PS = {"script": "Get-Date", "reason": "check clock"}


def test_meta_tiers():
    assert (OPS["ad_powershell"].tier, OPS["ad_powershell"].toolset) == ("H", "ad_meta")
    assert (OPS["sysadmin_audit_log"].tier, OPS["sysadmin_audit_log"].toolset) == ("R", "ad_meta")
    assert OPS["ad_powershell"].local is not None and OPS["sysadmin_audit_log"].local is not None


def test_powershell_is_blocked_by_policy_when_disabled():
    d = decide(OPS["ad_powershell"], PS, Settings())
    assert d.action == "block" and "disabled" in d.reason
    assert decide(OPS["ad_powershell"], PS, Settings(enable_powershell_escape=True)).action == "approve"


def test_disabled_powershell_is_blocked_and_audited(make_service, runner, audit):
    out = make_service().call("ad_powershell", PS, actor="dashboard", approved=True)
    assert out["ok"] is False and out["error"]["type"] == "PolicyBlocked"
    assert runner.calls == []
    assert audit.query(limit=1)[0]["decision"].startswith("blocked:")


def test_enabled_powershell_wraps_script_and_needs_approval(make_service, runner, settings, audit):
    svc = make_service(settings=replace(settings, enable_powershell_escape=True))
    assert svc.call("ad_powershell", PS, actor="agent")["error"]["type"] == "ApprovalRequired"
    runner.responses["<text>"] = {"now": "2026-11-05T12:00:00Z"}
    out = svc.call("ad_powershell", PS, actor="agent", session="s1", approved=True)
    assert out == {"ok": True, "data": {"now": "2026-11-05T12:00:00Z"}}
    assert runner.calls[-1][1]["text"] == "Invoke-Op {\nGet-Date\n}"
    row = audit.query(limit=1)[0]
    assert (row["tool"], row["tier"], row["decision"]) == ("ad_powershell", "H", "approved")


def test_powershell_rejects_oversized_scripts(make_service, settings):
    svc = make_service(settings=replace(settings, enable_powershell_escape=True))
    out = svc.call("ad_powershell", {"script": "x" * 20001, "reason": "r"}, actor="agent", approved=True)
    assert out["error"]["type"] == "InvalidArguments"


def test_audit_log_tool_queries_rows(make_service, audit):
    for actor in ("agent", "dashboard", "agent"):
        audit.record(actor=actor, session="", tool="ad_user_unlock", target="bob", tier="W",
                     decision="approved", result="ok", params={"identity": "bob"})
    svc = make_service()
    out = svc.call("sysadmin_audit_log", {"limit": 2}, actor="agent")
    assert out["ok"] and len(out["data"]["items"]) == 2
    only = svc.call("sysadmin_audit_log", {"actor": "dashboard"}, actor="agent")
    assert [r["actor"] for r in only["data"]["items"]] == ["dashboard"]


def test_long_powershell_script_is_audited_in_full():
    from sysadmin.audit import AuditLog
    import sqlite3

    log = AuditLog(sqlite3.connect(":memory:", check_same_thread=False))
    script = "Get-Process\n" * 1500 + "Write-Output END"
    log.record(actor="agent", session="", tool="ad_powershell", target="", tier="H", decision="approved", result="ok", params={"script": script})
    assert log.query()[0]["params"]["script"].endswith("Write-Output END")
