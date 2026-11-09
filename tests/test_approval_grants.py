"""The handler runs with the tier the pre_tool_call hook approved, not a blanket approved=True."""

import json

import pytest

from sysadmin import approvals, hooks, runtime, tools
from sysadmin.registry import Op, Param


@pytest.fixture
def svc(monkeypatch, make_service, scratch_ops, runner):
    p = (Param("identity", "string", "x", required=True),)
    scratch_ops(Op("t_g_write", "t", "W", "t_g_write", "d", params=p, identities=("identity",)))
    scratch_ops(Op("t_g_high", "t", "H", "t_g_high", "d", params=p, identities=("identity",)))
    runner.responses["t_g_write"] = {"done": True}
    runner.responses["t_g_high"] = {"done": True}
    service = make_service()
    monkeypatch.setattr(runtime, "get_service", lambda: service)
    approvals.clear()
    yield service
    approvals.clear()


def run(tool, args, session="s1"):
    return json.loads(tools.make_handler(tool)(args, session_id=session))


def test_hook_grant_lets_the_approved_call_run_once(svc):
    assert hooks.pre_tool_call(tool_name="t_g_write", args={"identity": "bob"}, session_id="s1")["action"] == "approve"
    assert run("t_g_write", {"identity": "bob"})["ok"] is True
    # The grant is used up: the same call again without a fresh approval is refused.
    again = run("t_g_write", {"identity": "bob"})
    assert again["ok"] is False and "approval" in json.dumps(again).lower()


def test_no_grant_means_nothing_was_approved(svc):
    out = run("t_g_write", {"identity": "bob"})
    assert out["ok"] is False and "approval" in json.dumps(out).lower()


def test_grant_is_bound_to_session_and_arguments(svc):
    hooks.pre_tool_call(tool_name="t_g_write", args={"identity": "bob"}, session_id="s1")
    assert run("t_g_write", {"identity": "alice"})["ok"] is False
    assert run("t_g_write", {"identity": "bob"}, session="other")["ok"] is False
    assert run("t_g_write", {"identity": "bob"})["ok"] is True


def test_write_approval_does_not_cover_a_call_that_became_high_risk(svc):
    approvals.grant("s1", "t_g_high", {"identity": "bob"}, "W")  # approved as a write; policy now says high-risk
    out = run("t_g_high", {"identity": "bob"})
    assert out["ok"] is False and "approve it again" in json.dumps(out)


def test_high_risk_grant_runs_high_risk_call(svc):
    assert "HIGH-RISK" in hooks.pre_tool_call(tool_name="t_g_high", args={"identity": "bob"}, session_id="s1")["message"]
    assert run("t_g_high", {"identity": "bob"})["ok"] is True


def test_a_new_hook_decision_replaces_an_old_grant(svc, monkeypatch):
    hooks.pre_tool_call(tool_name="t_g_write", args={"identity": "bob"}, session_id="s1")
    monkeypatch.setattr(hooks, "decide", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom")))
    hooks.pre_tool_call(tool_name="t_g_write", args={"identity": "bob"}, session_id="s1")  # fails to the generic prompt
    assert approvals.take("s1", "t_g_write", {"identity": "bob"}) is False
