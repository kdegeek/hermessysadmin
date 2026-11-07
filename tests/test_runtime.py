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


def test_build_service_picks_transport_from_resolved_settings():
    from sysadmin.local_transport import LocalTransport
    from sysadmin.transport import PsrpTransport, UnconfiguredTransport

    pick = runtime.make_transport
    from sysadmin.transport_pool import TransportPool
    for s in (Settings(transport="local", run_as="hermes_user"), Settings(transport="local", run_as="account", username="C\\u", password="p")):
        pool = pick(s)
        assert isinstance(pool, TransportPool)
        member = pool._factory()
        assert isinstance(member, LocalTransport)
        assert member._credential_check is pool._factory()._credential_check  # one shared check for the pool
    assert isinstance(pick(Settings(transport="local", run_as="account")), UnconfiguredTransport)
    assert isinstance(pick(Settings(host="dc01", username="u", password="p")), PsrpTransport)
    assert isinstance(pick(Settings()), UnconfiguredTransport)
    svc = runtime.build_service(Settings(transport="local", run_as="hermes_user"))
    assert isinstance(svc.runner._transport, TransportPool)
    svc.runner.close()
