from dataclasses import replace

from sysadmin import api, ops  # noqa: F401
from sysadmin.config import Settings
from sysadmin.errors import ConnectionFailed
from sysadmin.registry import OPS

DC = {
    "name": "DC01", "site": "HQ", "reachable": True,
    "services": {"NTDS": "Running", "Netlogon": "Running", "KDC": "Running", "DNS": "Running", "W32Time": "Running"},
    "sysvol_shared": True, "netlogon_shared": True, "time_skew_seconds": 0.2, "replication": {"failures": 0},
}


def test_list_ops_is_the_registry():
    out = api.list_ops()
    names = [o["name"] for o in out["data"]["items"]]
    assert names == sorted(n for n in OPS if not n.startswith("t_"))
    unlock = next(o for o in out["data"]["items"] if o["name"] == "ad_user_unlock")
    assert unlock["tier"] == "W" and unlock["params"][0]["name"] == "identity"


def test_reads_run_without_confirm(make_service, runner, audit):
    runner.responses["ad_search"] = {"items": []}
    assert api.run_op(make_service(), "ad_search", {"args": {"query": "bob"}}) == {"ok": True, "data": {"items": []}}
    assert audit.query() == []


def test_write_without_confirm_is_refused_and_not_run(make_service, runner):
    out = api.run_op(make_service(), "ad_user_unlock", {"args": {"identity": "bob"}})
    assert out["ok"] is False and out["error"]["type"] == "ApprovalRequired"
    assert out["error"]["tier"] == "W" and out["error"]["confirm_name"] == "bob"
    assert runner.calls == []


def test_confirmed_write_runs_and_audits_as_dashboard(make_service, runner, audit):
    out = api.run_op(make_service(), "ad_user_unlock", {"args": {"identity": "bob"}, "confirm": True})
    assert out["ok"] is True
    row = audit.query(limit=1)[0]
    assert (row["actor"], row["decision"]) == ("dashboard", "confirmed")


def test_high_risk_needs_matching_typed_name(make_service, runner):
    svc = make_service()
    body = {"args": {"identity": "bob"}, "confirm": True, "confirm_name": "bobby"}
    out = api.run_op(svc, "ad_user_delete", body)
    assert out["error"]["type"] == "InvalidArguments" and runner.calls == []
    assert api.run_op(svc, "ad_user_delete", {**body, "confirm_name": "  BOB "})["ok"] is True


def test_blocked_write_is_audited_once(make_service, audit):
    out = api.run_op(make_service(), "ad_user_unlock", {"args": {"identity": "krbtgt"}, "confirm": True})
    assert out["error"]["type"] == "PolicyBlocked"
    assert [r["decision"][:8] for r in audit.query()] == ["blocked:"]


def test_permissive_mode_runs_writes_without_confirm(make_service, settings):
    svc = make_service(settings=replace(settings, mode="permissive"))
    assert api.run_op(svc, "ad_user_unlock", {"args": {"identity": "bob"}})["ok"] is True


def test_decision_describes_the_dialog(make_service):
    out = api.decision(make_service(), "ad_user_delete", {"args": {"identity": "bob"}})
    assert out["data"] == {
        "action": "approve", "tier": "H", "reason": "High-risk change: requires approval with a preview.",
        "needs_preview": True, "target": "bob", "confirm_name": "bob", "type_to_confirm": True,
    }


def test_confirm_name_choice():
    assert api.confirm_name_of(OPS["gpo_link"], {"identity": "Screen Lock", "target": "OU=Fin,DC=corp"}) == "Screen Lock"
    assert api.confirm_name_of(OPS["ad_group_add_member"], {"group": "Domain Admins", "members": ["bob"]}) == "Domain Admins"
    assert api.confirm_name_of(OPS["rdp_set_enabled"], {"hosts": ["DC01", "DC02"], "enabled": False}) == "DC01"
    assert api.confirm_name_of(OPS["ad_powershell"], {"script": "Get-Date", "reason": "r"}) == "ad_powershell"


def test_preview_passes_through(make_service, runner):
    runner.responses["ad_user_delete"] = lambda p: {"summary": "Delete bob", "preview": p.get("Preview")}
    out = api.preview(make_service(), "ad_user_delete", {"args": {"identity": "bob"}})
    assert out == {"ok": True, "data": {"summary": "Delete bob", "preview": True}}


def test_unknown_op_and_bad_args_are_errors(make_service):
    svc = make_service()
    assert api.run_op(svc, "nope", {})["error"]["type"] == "InvalidArguments"
    assert api.decision(svc, "ad_user_unlock", {"args": {}})["error"]["type"] == "InvalidArguments"
    assert api.run_op(svc, "ad_user_unlock", {"args": "bob"})["error"]["type"] == "InvalidArguments"


def test_overview_builds_kpis_and_reports_section_errors(make_service, runner):
    runner.responses.update({
        "ad_domain_overview": {"domain": "corp.example.local", "counts": {
            "users": 1240, "users_enabled": 1152, "users_never_expire": 9, "users_stale": 31, "users_disabled": 88, "users_locked": 3, "passwords_expiring": 17,
            "computers": 410, "computers_stale": 22, "gpos": 41}},
        "ad_dc_health": {"items": [DC], "errors": []},
        "rdp_sessions": {"hosts": [{"host": "SRV1", "lines": [" alice  rdp-tcp#2  2  Active  .  11/4/2026 8:01 AM"]}], "errors": []},
        "gpo_list": {"items": [{"name": "Old", "status": "AllSettingsEnabled", "links": [],
                                "user_version": {"ad": 1, "sysvol": 1}, "computer_version": {"ad": 1, "sysvol": 1}}]},
        "backup_status": ConnectionFailed("SRV-FS01 unreachable"),
    })
    out = api.overview(make_service())
    k = out["data"]["kpis"]
    assert (k["users"], k["users_locked"], k["gpos_needing_attention"], k["rdp_active"], k["dc_status"]) == (1240, 3, 1, 1, "ok")
    assert k["oldest_system_state"] is None and k["backups_bad"] is None
    assert out["data"]["errors"]["backups"]["type"] == "ConnectionError"
    assert out["data"]["domain"]["domain"] == "corp.example.local"
    assert out["data"]["backups"] == [] and k["backups_total"] is None
    assert (k["gpos_unlinked"], k["users_enabled"]) == (1, 1152)
    assert (k["users_never_expire"], k["users_stale"]) == (9, 31)


def test_overview_maps_backup_list_and_summary(make_service, runner):
    runner.responses.update({
        "ad_domain_overview": {"domain": "d", "counts": {}},
        "ad_dc_health": {"items": [DC], "errors": []},
        "rdp_sessions": {"hosts": [], "errors": []},
        "gpo_list": {"items": [{"name": "A", "status": "AllSettingsEnabled", "links": [{"enabled": True}],
                                "user_version": {"ad": 1, "sysvol": 1}, "computer_version": {"ad": 1, "sysvol": 1}},
                               {"name": "B", "status": "AllSettingsEnabled", "links": [],
                                "user_version": {"ad": 1, "sysvol": 1}, "computer_version": {"ad": 1, "sysvol": 1}}]},
        "backup_status": {"results": [{"host": "SRV1", "installed": True, "policy": True, "versions": 1,
                                       "last_success": "2026-11-05T00:00:00+00:00", "last_system_state": "2026-11-05T00:00:00+00:00",
                                       "last_result_hr": 0}], "errors": []},
    })
    d = api.overview(make_service())["data"]
    assert [b["host"] for b in d["backups"]] == ["SRV1"] and set(d["backups"][0]) == {"host", "age_hours", "state"}
    assert d["kpis"]["gpos_unlinked"] == 1 and d["kpis"]["backups_total"] == 1


def test_health_unconfigured_makes_no_remote_call(make_service, runner):
    out = api.health(make_service(settings=Settings()))
    assert out["data"]["configured"] is False and out["data"]["status"] == "unconfigured"
    assert runner.calls == []


def test_health_configured_reports_dc_status(make_service, runner):
    runner.responses["ad_dc_health"] = {"items": [{**DC, "reachable": False}], "errors": []}
    d = api.health(make_service())["data"]
    assert (d["configured"], d["status"], d["host"], d["mode"]) == (True, "bad", "dc01.corp.example.local", "strict")



def test_health_reports_transport_and_run_as(make_service, runner):
    runner.responses["ad_dc_health"] = {"items": [DC], "errors": []}
    d = api.health(make_service(settings=Settings(transport="local", run_as="account", username="CORP\\svc", password="pw")))["data"]
    assert (d["transport"], d["run_as"], d["run_as_user"]) == ("local", "account", "CORP\\svc")
    assert "pw" not in str(d.values())
    d = api.health(make_service(settings=Settings(transport="local", run_as="hermes_user")))["data"]
    assert (d["transport"], d["run_as"], d["run_as_user"]) == ("local", "hermes_user", None)
    d = api.health(make_service())["data"]
    assert (d["transport"], d["run_as"], d["run_as_user"]) == ("winrm", None, None)

def test_audit_and_refresh(make_service, audit):
    audit.record(actor="dashboard", session="", tool="ad_user_unlock", target="bob", tier="W",
                 decision="confirmed", result="ok", params={})
    svc = make_service()
    assert api.audit(svc, limit=10, actor="dashboard", decision=None)["data"]["items"][0]["target"] == "bob"
    assert api.refresh(svc) == {"ok": True, "data": {"refreshed": True}}


def test_escalated_non_destructive_write_needs_confirm_but_no_typed_name(make_service, runner):
    svc = make_service()
    args = {"group": "Domain Admins", "members": ["bob"]}
    out = api.run_op(svc, "ad_group_add_member", {"args": args})
    assert out["ok"] is False and out["error"]["tier"] == "H" and runner.calls == []
    assert api.decision(svc, "ad_group_add_member", {"args": args})["data"]["type_to_confirm"] is False
    assert api.run_op(svc, "ad_group_add_member", {"args": args, "confirm": True})["ok"] is True


def test_destructive_ops_are_exactly_the_irreversible_ones():
    assert sorted(n for n, o in OPS.items() if o.destructive) == ["ad_powershell", "ad_user_delete", "gpo_delete", "gpo_restore"]
    assert all(OPS[n].tier == "H" for n in OPS if OPS[n].destructive)


def test_high_risk_without_typed_name_is_refused(make_service, runner):
    out = api.run_op(make_service(), "ad_user_delete", {"args": {"identity": "bob"}, "confirm": True})
    assert out["ok"] is False and runner.calls == []


def test_confirm_must_be_literal_true(make_service, runner):
    svc = make_service()
    for confirm in ("true", 1, "yes"):
        out = api.run_op(svc, "ad_user_unlock", {"args": {"identity": "bob"}, "confirm": confirm})
        assert out["ok"] is False
    assert runner.calls == []


def test_disabled_escape_hatch_never_runs(make_service, runner):
    body = {"args": {"script": "Get-Process", "reason": "test"}, "confirm": True, "confirm_name": "Get-Process"}
    out = api.run_op(make_service(), "ad_powershell", body)
    assert out["ok"] is False and out["error"]["type"] == "PolicyBlocked" and runner.calls == []


def test_read_only_mode_blocks_confirmed_writes(make_service, settings, runner):
    svc = make_service(settings=replace(settings, mode="read-only"))
    out = api.run_op(svc, "ad_user_unlock", {"args": {"identity": "bob"}, "confirm": True})
    assert out["error"]["type"] == "PolicyBlocked" and runner.calls == []


def test_test_ops_and_unknown_names_are_rejected(make_service, scratch_ops):
    from sysadmin.registry import Op

    scratch_ops(Op("t_api_hidden", "t", "R", "t_api_hidden", "d"))
    for name in ("t_api_hidden", "nope"):
        assert api.run_op(make_service(), name, {"args": {}})["ok"] is False
