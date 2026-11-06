from sysadmin import runtime
from sysadmin.config import Settings


def test_get_service_caches_per_settings_and_rebuilds_on_change(monkeypatch):
    runtime.reset()
    current = {"s": Settings(host="dc01", username="u", password="p")}
    monkeypatch.setattr(runtime, "load_settings", lambda: current["s"])
    a = runtime.get_service()
    assert runtime.get_service() is a
    assert a.settings.configured
    current["s"] = Settings()
    b = runtime.get_service()
    assert b is not a
    assert not b.settings.configured
    runtime.reset()


def test_notify_never_raises_without_hermes():
    runtime.notify("changed", {"op": "x"})


def test_reset_drops_audit_singleton(monkeypatch):
    runtime.reset()
    monkeypatch.setattr(runtime, "load_settings", lambda: Settings())
    first = runtime.get_service().audit
    assert runtime.get_service().audit is first
    runtime.reset()
    assert runtime.get_service().audit is not first
    runtime.reset()
