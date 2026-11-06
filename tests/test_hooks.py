import pytest

from sysadmin import hooks, runtime
from sysadmin.config import Settings
from sysadmin.registry import Op, Param


@pytest.fixture
def svc(monkeypatch, make_service, scratch_ops):
    p = (Param("identity", "string", "x", required=True),)
    scratch_ops(Op("t_h_read", "t", "R", "t_h_read", "d", params=p))
    scratch_ops(Op("t_h_write", "t", "W", "t_h_write", "d", params=p, identities=("identity",)))
    scratch_ops(Op("t_h_high", "t", "H", "t_h_high", "d", params=p, identities=("identity",), preview=True))
    scratch_ops(Op("t_h_high_np", "t", "H", "t_h_high_np", "d", params=(Param("script", "string", "s", required=True),)))
    service = make_service()
    monkeypatch.setattr(runtime, "get_service", lambda: service)
    return service


def test_read_and_unknown_tools_pass_through(svc):
    assert hooks.pre_tool_call(tool_name="t_h_read", args={"identity": "bob"}) is None
    assert hooks.pre_tool_call(tool_name="terminal", args={"cmd": "ls"}) is None


def test_write_requests_approval_with_stable_rule_key(svc):
    d = hooks.pre_tool_call(tool_name="t_h_write", args={"identity": "bob"}, session_id="s")
    assert d["action"] == "approve"
    assert d["rule_key"] == "hermes-sysadmin:t_h_write"
    assert d["message"].startswith("[hermes-sysadmin] Write: t_h_write → bob")


def test_high_risk_includes_preview_and_unique_rule_key(svc, runner):
    runner.responses["t_h_high"] = {"summary": "Delete bob", "changes": ["remove CN=bob"], "current": {"groups": ["A", "B"]}}
    a = hooks.pre_tool_call(tool_name="t_h_high", args={"identity": "bob"})
    b = hooks.pre_tool_call(tool_name="t_h_high", args={"identity": "bob"})
    assert a["action"] == "approve" and "HIGH-RISK" in a["message"]
    assert "Preview (no change made yet):" in a["message"]
    assert "Delete bob" in a["message"] and "• remove CN=bob" in a["message"] and "groups: A, B" in a["message"]
    assert a["rule_key"].startswith("hermes-sysadmin:t_h_high:once:")
    assert a["rule_key"] != b["rule_key"]


def test_high_risk_without_script_preview_shows_arguments(svc):
    d = hooks.pre_tool_call(tool_name="t_h_high_np", args={"script": "Get-Process"})
    assert "Get-Process" in d["message"]


def test_preview_failure_still_requests_approval(svc, runner):
    from sysadmin.errors import ConnectionFailed

    runner.responses["t_h_high"] = ConnectionFailed("down")
    d = hooks.pre_tool_call(tool_name="t_h_high", args={"identity": "bob"})
    assert d["action"] == "approve" and "unavailable" in d["message"]


def test_blocks_and_bad_args_are_left_to_the_handler(svc):
    assert hooks.pre_tool_call(tool_name="t_h_write", args={"identity": "krbtgt"}) is None
    assert hooks.pre_tool_call(tool_name="t_h_write", args={}) is None


def test_permissive_mode_skips_approval_for_writes(monkeypatch, make_service, svc):
    permissive = make_service(settings=Settings(host="h", username="u", password="p", mode="permissive"))
    monkeypatch.setattr(runtime, "get_service", lambda: permissive)
    assert hooks.pre_tool_call(tool_name="t_h_write", args={"identity": "bob"}) is None
    assert hooks.pre_tool_call(tool_name="t_h_high", args={"identity": "bob"})["action"] == "approve"


def test_unexpected_error_fails_to_approval_not_silence(monkeypatch, svc):
    def boom():
        raise RuntimeError("settings unreadable")

    monkeypatch.setattr(runtime, "get_service", boom)
    d = hooks.pre_tool_call(tool_name="t_h_write", args={"identity": "bob"})
    assert d["action"] == "approve" and "could not evaluate" in d["message"]


def test_post_tool_call_records_denials(svc, audit):
    hooks.post_tool_call(tool_name="t_h_write", args={"identity": "bob"}, result="BLOCKED: denied by user", status="blocked", session_id="s9")
    hooks.post_tool_call(tool_name="t_h_write", args={"identity": "bob"}, result="{}", status="success")
    hooks.post_tool_call(tool_name="terminal", args={}, result="x", status="blocked")
    rows = audit.query()
    assert len(rows) == 1
    assert rows[0]["decision"] == "denied: BLOCKED: denied by user" and rows[0]["session"] == "s9"


def test_format_preview_handles_non_dict():
    assert hooks.format_preview(["a", 1]) == '["a", 1]'
