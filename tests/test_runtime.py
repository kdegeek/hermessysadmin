from sysadmin import runtime
from sysadmin.config import Settings
from sysadmin.transport import PsrpTransport, UnconfiguredTransport


def test_get_service_caches_per_settings_and_rebuilds_on_change(monkeypatch):
    runtime.reset()
    current = {"s": Settings(host="dc01", username="u", password="p")}
    monkeypatch.setattr(runtime, "load_settings", lambda: current["s"])
    a = runtime.get_service()
    assert runtime.get_service() is a
    assert isinstance(a.runner._transport, PsrpTransport)
    current["s"] = Settings()
    b = runtime.get_service()
    assert b is not a
    assert isinstance(b.runner._transport, UnconfiguredTransport)
    runtime.reset()


def test_notify_never_raises_without_hermes():
    runtime.notify("changed", {"op": "x"})
