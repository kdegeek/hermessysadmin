import json

from sysadmin import api, commands, hooks, runtime, tools
from sysadmin.registry import OPS


def test_search_scores_title_and_tags(make_service):
    svc = make_service()
    out = svc.call("catalog_search", {"query": "disk"}, actor="agent")
    assert out["ok"] and out["data"]["items"][0]["id"] == "endpoint.disk_usage"


def test_search_filters_by_tier_and_target(make_service):
    out = make_service().call("catalog_search", {"tier": "R", "target": "endpoint"}, actor="agent")
    assert out["data"]["items"] and all(i["tier"] == "R" and i["target"] == "endpoint" for i in out["data"]["items"])


def test_get_returns_params_and_example(make_service):
    out = make_service().call("catalog_get", {"id": "endpoint.uptime"}, actor="agent")
    d = out["data"]
    assert d["id"] == "endpoint.uptime" and any(p["name"] == "MaxDays" for p in d["params"])
    assert d["example"]["computers"] == ["PC-NAME"] and d["module_installed"] is None


def test_get_unknown_id_is_invalid(make_service):
    out = make_service().call("catalog_get", {"id": "nope.nope"}, actor="agent")
    assert out["error"]["type"] == "InvalidArguments"


def test_catalog_run_routes_to_entry(monkeypatch, make_service, runner):
    svc = make_service()
    monkeypatch.setattr(runtime, "get_service", lambda: svc)
    runner.responses["catalog:endpoint/uptime.ps1"] = {"items": [], "errors": [], "summary": {"hosts": 1, "ok": 1, "failed": 0}}
    out = json.loads(tools.make_catalog_run_handler()({"id": "endpoint.uptime", "params": {"MaxDays": 5}, "computers": ["PC1"]}))
    assert out["ok"] is True
    script, params, _ = runner.calls[-1]
    assert script == "catalog:endpoint/uptime.ps1" and params["MaxDays"] == 5 and params["Computers"] == ["PC1"]


def test_catalog_run_rejects_non_catalog_ops(monkeypatch, make_service):
    monkeypatch.setattr(runtime, "get_service", lambda: make_service())
    handler = tools.make_catalog_run_handler()
    for bad in ("../ad_user_delete", "ad.user_delete", "nope.nope"):
        out = json.loads(handler({"id": bad}))
        assert out["ok"] is False and out["error"]["type"] == "InvalidArguments"


def test_hook_gates_catalog_write_with_entry_tier(monkeypatch, make_service, scratch_ops):
    from sysadmin.registry import Op, Param
    op = Op("t_catwrite", "catalog", "W", "x", "d", params=(Param("computers", "array", "c"),), catalog=True,
            meta={"id": "t.catwrite", "title": "Cat write"})
    scratch_ops(op)
    OPS["cat.t.catwrite"] = op
    try:
        svc = make_service()
        monkeypatch.setattr(runtime, "get_service", lambda: svc)
        res = hooks.pre_tool_call("catalog_run", {"id": "t.catwrite", "computers": ["PC1"]})
        assert res["action"] == "approve" and "catalog t.catwrite (Cat write)" in res["message"]
        assert res["message"].splitlines()[0].startswith("[hermes-sysadmin] Write: catalog t.catwrite")
    finally:
        OPS.pop("cat.t.catwrite", None)


def test_hook_ignores_catalog_read_and_bad_args(monkeypatch, make_service):
    monkeypatch.setattr(runtime, "get_service", lambda: make_service())
    assert hooks.pre_tool_call("catalog_run", {"id": "endpoint.uptime", "computers": ["PC1"]}) is None
    assert hooks.pre_tool_call("catalog_run", {"id": "../x"}) is None


def test_api_catalog_lists_categories(make_service):
    out = api.catalog(make_service())
    assert out["ok"] and any(c["name"] == "Endpoint health" for c in out["data"]["categories"])
    assert all("example" not in i for i in out["data"]["items"])


def test_ad_catalog_and_run(monkeypatch, make_service, runner):
    svc = make_service()
    monkeypatch.setattr(runtime, "get_service", lambda: svc)
    runner.responses["catalog:endpoint/uptime.ps1"] = {
        "items": [{"host": "PC1", "days": 3}], "errors": [{"host": "PC2", "message": "unreachable"}]}
    ad = commands.make_command(None)
    assert "`endpoint.uptime`" in ad("catalog uptime")
    out = ad("run endpoint.uptime MaxDays=5 on PC1,PC2")
    assert "PC1: days=3" in out and "PC2: unreachable" in out
    _, params, _ = runner.calls[-1]
    assert params["MaxDays"] == 5 and params["Computers"] == ["PC1", "PC2"]
