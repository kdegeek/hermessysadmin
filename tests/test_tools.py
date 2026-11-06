import json

from sysadmin import ops  # noqa: F401
from sysadmin import runtime, tools
from sysadmin.registry import OPS


class FakeCtx:
    def __init__(self):
        self.tools = {}

    def register_tool(self, **kwargs):
        self.tools[kwargs["name"]] = kwargs


def test_register_tools_registers_every_real_op_with_schema():
    ctx = FakeCtx()
    names = tools.register_tools(ctx)
    real = sorted(n for n in OPS if not n.startswith("t_"))
    assert names == real
    entry = ctx.tools["ad_search"]
    assert entry["toolset"] == "ad_domain"
    assert entry["schema"]["name"] == "ad_search"
    assert entry["emoji"] == "🏢"
    assert callable(entry["handler"])


def test_handler_returns_json_and_marks_agent_actor(monkeypatch, make_service, runner):
    runner.responses["ad_search"] = {"items": []}
    svc = make_service()
    monkeypatch.setattr(runtime, "get_service", lambda: svc)
    out = tools.make_handler("ad_search")({"query": "bob"}, session_id="s1", task_id="t")
    assert json.loads(out) == {"ok": True, "data": {"items": []}}
    assert runner.calls[0][0] == "ad_search"


def test_handler_never_raises(monkeypatch):
    def boom():
        raise RuntimeError("no runtime")

    monkeypatch.setattr(runtime, "get_service", boom)
    out = json.loads(tools.make_handler("ad_search")({"query": "x"}))
    assert out["ok"] is False and out["error"]["type"] == "InternalError"
