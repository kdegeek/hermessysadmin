import pytest

from sysadmin.config import Settings
from sysadmin.errors import NotFound
from sysadmin.registry import Op, Param


@pytest.fixture
def ops(scratch_ops):
    p = (Param("identity", "string", "x", required=True), Param("password", "string", "pw"))
    return {
        "read": scratch_ops(Op("t_s_read", "t", "R", "t_s_read", "d", params=p[:1], cache_ttl=30)),
        "read_nocache": scratch_ops(Op("t_s_read2", "t", "R", "t_s_read2", "d", params=p[:1])),
        "write": scratch_ops(Op("t_s_write", "t", "W", "t_s_write", "d", params=p, identities=("identity",))),
        "high": scratch_ops(Op("t_s_high", "t", "H", "t_s_high", "d", params=p[:1], identities=("identity",), preview=True)),
        "post": scratch_ops(Op("t_s_post", "t", "R", "t_s_post", "d", post=lambda data, args, s: {"n": len(data["items"])})),
        "esc": scratch_ops(Op("t_s_esc", "t", "W", "t_s_esc", "d", params=p[:1], escalate=lambda a, s, f: True)),
    }


def test_read_runs_with_retry_and_no_audit(ops, make_service, runner, audit):
    runner.responses["t_s_read2"] = {"name": "bob"}
    result = make_service().call("t_s_read2", {"identity": "bob"}, actor="agent")
    assert result == {"ok": True, "data": {"name": "bob"}}
    assert runner.calls == [("t_s_read2", {"Identity": "bob"}, True)]
    assert audit.query() == []


def test_write_without_approval_is_refused_and_not_run(ops, make_service, runner, audit):
    result = make_service().call("t_s_write", {"identity": "bob"}, actor="agent")
    assert result["ok"] is False and result["error"]["type"] == "ApprovalRequired"
    assert runner.calls == []
    assert audit.query() == []


def test_approved_write_runs_audits_notifies_and_invalidates(ops, make_service, runner, audit, events):
    runner.responses["t_s_read"] = {"v": 1}
    runner.responses["t_s_write"] = {"done": True}
    svc = make_service()
    svc.call("t_s_read", {"identity": "bob"}, actor="agent")
    result = svc.call("t_s_write", {"identity": "bob", "password": "S3cret!"}, actor="agent", session="s1", approved=True)
    assert result == {"ok": True, "data": {"done": True}}
    assert runner.calls[-1] == ("t_s_write", {"Identity": "bob", "Password": "S3cret!"}, False)
    row = audit.query()[0]
    assert (row["actor"], row["session"], row["tool"], row["target"], row["tier"], row["decision"], row["result"]) == (
        "agent", "s1", "t_s_write", "bob", "W", "approved", "ok",
    )
    assert row["params"]["password"] == "[redacted]"
    assert events == [("changed", {"op": "t_s_write", "target": "bob", "actor": "agent"})]
    svc.call("t_s_read", {"identity": "bob"}, actor="agent")
    assert [c[0] for c in runner.calls].count("t_s_read") == 2


def test_dashboard_write_records_confirmed(ops, make_service, runner, audit):
    runner.responses["t_s_write"] = {}
    make_service().call("t_s_write", {"identity": "bob"}, actor="dashboard", approved=True)
    assert audit.query()[0]["decision"] == "confirmed"


def test_permissive_write_runs_without_approval(ops, make_service, runner, audit):
    runner.responses["t_s_write"] = {}
    svc = make_service(settings=Settings(host="h", username="u", password="p", mode="permissive"))
    assert svc.call("t_s_write", {"identity": "bob"}, actor="agent")["ok"] is True
    assert audit.query()[0]["decision"] == "allowed"


def test_read_only_mode_blocks_and_audits(ops, make_service, runner, audit):
    svc = make_service(settings=Settings(host="h", username="u", password="p", mode="read-only"))
    result = svc.call("t_s_write", {"identity": "bob"}, actor="agent", approved=True)
    assert result["error"]["type"] == "PolicyBlocked"
    assert runner.calls == []
    assert audit.query()[0]["decision"].startswith("blocked: ")


def test_protected_identity_blocked_even_when_approved(ops, make_service, runner, audit):
    result = make_service().call("t_s_high", {"identity": "krbtgt"}, actor="agent", approved=True)
    assert result["error"]["type"] == "PolicyBlocked"
    assert audit.query()[0]["tier"] == "P"
    assert runner.calls == []


def test_failed_write_is_audited_with_message(ops, make_service, runner, audit):
    runner.responses["t_s_write"] = NotFound("No user bob")
    result = make_service().call("t_s_write", {"identity": "bob"}, actor="agent", approved=True)
    assert result["error"]["type"] == "NotFound"
    assert audit.query()[0]["result"] == "failed: No user bob"


def test_read_cache_hits_within_ttl(ops, make_service, runner):
    now = {"t": 0.0}
    runner.responses["t_s_read"] = {"v": 1}
    svc = make_service(clock=lambda: now["t"])
    svc.call("t_s_read", {"identity": "bob"}, actor="dashboard")
    now["t"] = 10
    svc.call("t_s_read", {"identity": "bob"}, actor="dashboard")
    now["t"] = 31
    svc.call("t_s_read", {"identity": "bob"}, actor="dashboard")
    assert [c[0] for c in runner.calls].count("t_s_read") == 2


def test_post_processing_applies(ops, make_service, runner):
    runner.responses["t_s_post"] = {"items": [1, 2, 3]}
    assert make_service().call("t_s_post", {}, actor="agent")["data"] == {"n": 3}


def test_escalation_records_high_tier(ops, make_service, runner, audit):
    runner.responses["t_s_esc"] = {}
    make_service().call("t_s_esc", {"identity": "bob"}, actor="agent", approved=True)
    assert audit.query()[0]["tier"] == "H"


def test_inject_adds_settings_derived_params(scratch_ops, make_service, runner):
    scratch_ops(Op("t_s_inj", "t", "R", "t_s_inj", "d", inject=lambda s: {"Host": s.host}))
    runner.responses["t_s_inj"] = 1
    make_service().call("t_s_inj", {}, actor="agent")
    assert runner.calls == [("t_s_inj", {"Host": "dc01.corp.example.local"}, True)]


def test_preview_runs_script_with_preview_switch(ops, make_service, runner):
    runner.responses["t_s_high"] = {"summary": "Delete bob"}
    assert make_service().preview("t_s_high", {"identity": "bob"}) == {"ok": True, "data": {"summary": "Delete bob"}}
    assert runner.calls == [("t_s_high", {"Identity": "bob", "Preview": True}, True)]


def test_preview_for_op_without_script_preview_describes_args(ops, make_service, runner):
    result = make_service().preview("t_s_write", {"identity": "bob", "password": "x"})
    assert result["data"] == {"summary": "t_s_write on bob", "details": {"identity": "bob", "password": "[redacted]"}}
    assert runner.calls == []


def test_preview_of_protected_target_is_blocked(ops, make_service):
    assert make_service().preview("t_s_high", {"identity": "krbtgt"})["error"]["type"] == "PolicyBlocked"


def test_unknown_op_and_bad_args_are_invalid_arguments(ops, make_service):
    svc = make_service()
    assert svc.call("nope", {}, actor="agent")["error"]["type"] == "InvalidArguments"
    assert svc.call("t_s_write", {}, actor="agent")["error"]["type"] == "InvalidArguments"


def test_record_denied_audits_writes_only(ops, make_service, audit):
    svc = make_service()
    svc.record_denied("t_s_read", {"identity": "bob"}, actor="agent", session="s", reason="user")
    svc.record_denied("t_s_write", {"identity": "bob"}, actor="agent", session="s", reason="by user")
    rows = audit.query()
    assert len(rows) == 1 and rows[0]["decision"] == "denied: by user"


def test_unexpected_exception_becomes_internal_error(ops, make_service, runner):
    runner.responses["t_s_read2"] = RuntimeError("kaboom")
    assert make_service().call("t_s_read2", {"identity": "b"}, actor="agent")["error"]["type"] == "InternalError"


def test_facts_domain_controllers_none_when_lookup_unavailable(ops, make_service, runner):
    from sysadmin.errors import ConnectionFailed

    runner.responses["ad_dc_list"] = ConnectionFailed("down")  # used once ad_dc_list exists (Phase 2)
    assert make_service().facts.domain_controllers() is None
