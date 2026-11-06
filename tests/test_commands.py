from dataclasses import replace

import pytest

from sysadmin import commands, ops, runtime  # noqa: F401

DC = {
    "name": "DC01", "site": "HQ", "reachable": True,
    "services": {"NTDS": "Running", "Netlogon": "Running", "KDC": "Running", "DNS": "Running", "W32Time": "Running"},
    "sysvol_shared": True, "netlogon_shared": True, "time_skew_seconds": 0.2, "replication": {"failures": 0},
}


class Ctx:
    def __init__(self, answer="unlock"):
        self.answer, self.asked = answer, []

    def ask_choice(self, question, choices):
        self.asked.append((question, choices))
        return self.answer


@pytest.fixture
def run(monkeypatch, make_service):
    def go(text, ctx=None, svc=None):
        service = svc or make_service()
        monkeypatch.setattr(runtime, "get_service", lambda: service)
        return commands.make_command(ctx or Ctx())(text, session_id="cli-1")

    return go


def test_help_and_unknown(run):
    assert "/ad status" in run("")
    assert run("frobnicate").startswith("Unknown subcommand 'frobnicate'")


def test_status(run, runner):
    runner.responses["ad_domain_overview"] = {
        "domain": "corp.example.local", "netbios": "CORP", "forest": "corp.example.local", "expiring_days": 7,
        "counts": {"users": 1240, "users_disabled": 88, "users_locked": 3, "passwords_expiring": 17,
                   "computers": 410, "computers_stale": 22, "gpos": 41},
    }
    runner.responses["ad_dc_health"] = {"items": [DC], "errors": []}
    out = run("status")
    assert "**corp.example.local** (CORP)" in out
    assert "Users 1240 · disabled 88 · locked 3" in out
    assert "🟢 DC01 (HQ)" in out


def test_user(run, runner):
    runner.responses["ad_user_get"] = {
        "sam": "bob", "name": "Bob Lee", "ou": "OU=Staff,DC=corp", "enabled": True, "locked": True,
        "last_logon": "2026-11-04T08:00:00Z", "password_expires": None, "groups": ["Finance", "VPN Users"],
    }
    out = run("user bob")
    assert "**Bob Lee** (bob)" in out and "🔒 locked" in out and "Finance, VPN Users" in out
    assert run("user") == "Usage: /ad user <name>"


def test_unlock_confirmed_runs_and_audits_as_command(run, runner, audit):
    ctx = Ctx("unlock")
    out = run("unlock bob", ctx)
    assert out == "✅ Unlocked bob."
    assert ctx.asked and "Unlock bob?" in ctx.asked[0][0]
    assert runner.calls[-1][0] == "ad_user_unlock"
    row = audit.query(limit=1)[0]
    assert (row["actor"], row["decision"], row["session"]) == ("command", "approved", "cli-1")


def test_unlock_cancelled_records_denial(run, runner, audit):
    out = run("unlock bob", Ctx(None))
    assert out == "Cancelled — bob was not unlocked."
    assert all(c[0] != "ad_user_unlock" for c in runner.calls)
    assert audit.query(limit=1)[0]["decision"].startswith("denied:")


def test_unlock_protected_is_blocked_without_prompt(run):
    ctx = Ctx()
    out = run("unlock krbtgt", ctx)
    assert out.startswith("⛔") and "protected" in out
    assert ctx.asked == []


def test_unlock_permissive_skips_prompt(run, make_service, settings, runner):
    ctx = Ctx()
    svc = make_service(settings=replace(settings, mode="permissive"))
    assert run("unlock bob", ctx, svc) == "✅ Unlocked bob."
    assert ctx.asked == []


def test_sessions(run, runner):
    runner.responses["rdp_sessions"] = {
        "hosts": [{"host": "SRV1", "lines": [" alice  rdp-tcp#2  2  Active  .  11/4/2026 8:01 AM"]}], "errors": [],
    }
    out = run("sessions SRV1")
    assert runner.calls[-1][1]["Hosts"] == ["SRV1"]
    assert "1 session(s) on 1 host(s)" in out and "SRV1 · alice · #2 · active" in out


def test_backups(run, runner):
    runner.responses["backup_status"] = {
        "results": [{"host": "SRV-RDS01", "installed": False, "policy": False, "versions": 0, "job": None}],
        "errors": [{"host": "SRV9", "message": "unreachable"}],
    }
    out = run("backups")
    assert "⚪ SRV-RDS01 — none · Windows Server Backup feature not installed" in out
    assert "🔴 SRV9 — unreachable" in out


def test_command_never_raises(monkeypatch):
    def boom():
        raise RuntimeError("no runtime")

    monkeypatch.setattr(runtime, "get_service", boom)
    assert commands.make_command(Ctx())("status").startswith("⚠️ /ad status failed")
