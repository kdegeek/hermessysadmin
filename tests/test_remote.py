import pytest

from sysadmin import catalog
from sysadmin.config import Settings
from sysadmin.errors import InvalidArguments
from sysadmin.ops import remote
from sysadmin.policy import decide
from sysadmin.registry import OPS


def test_shadow_command_flags():
    assert remote.shadow_command("PC1.corp", 3) == "mstsc.exe /shadow:3 /v:PC1.corp /control"
    assert remote.shadow_command("PC1", 3, control=False, consent=False) == "mstsc.exe /shadow:3 /v:PC1 /noConsentPrompt"


def test_assist_command_and_cmd_file():
    assert remote.assist_command("PC1") == "msra.exe /offerRA PC1"
    assert remote.cmd_file("x", "note") == "@echo off\r\nrem note\r\nx\r\n"


@pytest.mark.parametrize("bad", ["PC1 & calc", "-x", "", "a" * 300, "PC1\r\n"])
def test_bad_hosts_rejected(bad):
    with pytest.raises(InvalidArguments):
        remote.shadow_command(bad, 1)
    with pytest.raises(InvalidArguments):
        remote.assist_command(bad)


def test_no_consent_shadow_escalates():
    s = Settings(host="dc01", username="u", password="p")
    op = OPS["remote_shadow_command"]
    assert decide(op, {"computer": "PC1", "session_id": 1, "consent": True}, s).tier == "R"
    assert decide(op, {"computer": "PC1", "session_id": 1, "consent": False}, s).tier == "H"
    assert decide(op, {"computer": "PC1", "session_id": 1, "consent": False}, Settings(mode="read-only")).action == "block"


def test_shadow_op_output():
    out = OPS["remote_shadow_command"].local(None, {"computer": "PC1", "session_id": 4})
    assert out["filename"] == "shadow-PC1-4.cmd"
    assert out["command"].startswith("mstsc.exe /shadow:4 /v:PC1")
    assert out["cmd_file"].endswith(out["command"] + "\r\n")
    assert OPS["remote_assist_command"].local(None, {"computer": "PC1"})["command"] == "msra.exe /offerRA PC1"


def test_access_check_maps_fixes():
    raw = {"rdp_enabled": False, "nla": True, "rdp_firewall": False, "rdp_users": ["CORP\\bob"], "shadow": None,
           "ra_unsolicited": False, "ra_firewall": True}
    rows = remote.access_rows(raw)
    by = {r["key"]: r for r in rows}
    assert [r["key"] for r in rows] == ["rdp_enabled", "nla", "rdp_firewall", "rdp_users", "shadow_policy",
                                         "ra_unsolicited", "ra_firewall"]
    assert by["rdp_enabled"]["fix"] == "remote.enable_rdp" and by["rdp_enabled"]["ok"] is False
    assert by["shadow_policy"]["ok"] is False and by["rdp_users"]["ok"] is None
    assert by["rdp_users"]["value"] == ["CORP\\bob"] and by["rdp_users"]["fix"] == "remote.add_rdp_user"
    assert by["nla"]["ok"] is True and by["ra_firewall"]["fix"] == "remote.enable_remote_assistance"
    assert remote.access_rows({"shadow": 2})[4]["ok"] is True
    assert remote.access_rows({"shadow": 0})[4]["ok"] is False


def test_sessions_post_parses_quser():
    data = {"items": [{"host": "PC1", "lines": [" USERNAME  SESSIONNAME  ID  STATE  IDLE TIME  LOGON TIME",
                                                ">bob       console       1  Active      none   11/6/2026 8:00 AM"]},
                      {"host": "PC2", "lines": ["No User exists for *"]}],
            "errors": [], "summary": {"hosts": 2, "ok": 2, "failed": 0}}
    out = OPS["remote_sessions"].post(data, {}, None)
    assert len(out["items"]) == 1
    assert out["items"][0].items() >= {"host": "PC1", "user": "bob", "id": 1, "state": "active", "idle": "none",
                                       "idle_minutes": 0, "logon": "11/6/2026 8:00 AM"}.items()
    assert out["summary"]["sessions"] == 1


def test_remote_fix_entries_registered():
    ids = {o.meta["id"] for o in catalog.entries()}
    assert {"remote.enable_rdp", "remote.set_nla", "remote.add_rdp_user", "remote.set_shadow_policy",
            "remote.enable_remote_assistance", "remote.open_rdp_firewall", "remote.send_message",
            "remote.lock_workstation", "remote.logoff_session", "remote.restart_computer"} <= ids
    assert OPS["cat.remote.restart_computer"].tier == "H"
    assert OPS["cat.remote.restart_computer"].preview


def test_no_consent_shadow_needs_confirm_in_dashboard_flow(make_service, audit):
    from sysadmin import api

    svc = make_service()
    body = {"args": {"computer": "PC1", "session_id": 1, "consent": False}}
    first = api.run_op(svc, "remote_shadow_command", body)
    assert not first["ok"] and first["error"]["type"] == "ApprovalRequired"
    assert audit.query() == []
    done = api.run_op(svc, "remote_shadow_command", {**body, "confirm": True})
    assert done["ok"] and len(audit.query()) == 1
    d = api.decision(svc, "remote_shadow_command", body)["data"]
    assert d["tier"] == "H" and d["type_to_confirm"] is False
