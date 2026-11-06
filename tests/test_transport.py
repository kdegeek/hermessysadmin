from types import SimpleNamespace

import pytest
import requests

from sysadmin.config import Settings
from sysadmin.errors import ConnectionFailed, NotConfigured, RemoteScriptError, SysadminError, Timeout
from sysadmin.transport import PsrpTransport, UnconfiguredTransport

SETTINGS = Settings(host="dc01", username="CORP\\svc", password="pw")


class FakePool:
    def __init__(self, responder):
        self.responder = responder
        self.closed = False
        self.prelude_runs = 0

    def open(self):
        pass

    def close(self):
        self.closed = True


class FakePS:
    def __init__(self, pool):
        self.pool = pool
        self.script = None
        self.local = None
        self.params = {}
        self.had_errors = False
        self.streams = SimpleNamespace(error=[])

    def add_script(self, script, use_local_scope=True):
        self.script = script
        self.local = use_local_scope
        return self

    def add_parameter(self, name, value):
        self.params[name] = value
        return self

    def invoke(self):
        return self.pool.responder(self)


def make(responder):
    pools = []

    def pool_factory(settings):
        pool = FakePool(responder)
        pools.append(pool)
        return pool

    t = PsrpTransport(SETTINGS, "PRELUDE", pool_factory=pool_factory, ps_factory=FakePS)
    return t, pools


def test_prelude_runs_once_in_global_scope_with_credentials():
    seen = []

    def responder(ps):
        seen.append((ps.script, ps.local, dict(ps.params)))
        return ['{"ok":true}'] if ps.script != "PRELUDE" else []

    t, pools = make(responder)
    assert t.invoke("SCRIPT", {"Identity": "bob"}) == ['{"ok":true}']
    assert t.invoke("SCRIPT", {"Identity": "amy"}) == ['{"ok":true}']
    assert len(pools) == 1
    assert seen[0] == ("PRELUDE", False, {"User": "CORP\\svc", "Pass": "pw"})
    assert seen[1] == ("SCRIPT", True, {"Identity": "bob"})
    assert seen[2] == ("SCRIPT", True, {"Identity": "amy"})


def test_connection_error_drops_pool_and_reconnects_next_call():
    calls = {"n": 0}

    def responder(ps):
        if ps.script == "PRELUDE":
            return []
        calls["n"] += 1
        if calls["n"] == 1:
            raise requests.exceptions.ConnectionError("refused")
        return ["{}"]

    t, pools = make(responder)
    with pytest.raises(ConnectionFailed):
        t.invoke("S", {})
    assert pools[0].closed
    assert t.invoke("S", {}) == ["{}"]
    assert len(pools) == 2


def test_read_timeout_maps_to_timeout():
    def responder(ps):
        if ps.script == "PRELUDE":
            return []
        raise requests.exceptions.ReadTimeout("slow")

    t, _ = make(responder)
    with pytest.raises(Timeout):
        t.invoke("S", {})


def test_errors_without_output_raise_remote_script_error():
    def responder(ps):
        if ps.script != "PRELUDE":
            ps.had_errors = True
            ps.streams.error = ["The term 'Get-ADUser' is not recognized"]
        return []

    t, _ = make(responder)
    with pytest.raises(RemoteScriptError, match="Get-ADUser"):
        t.invoke("S", {})


def test_prelude_failure_raises_and_closes_pool():
    def responder(ps):
        ps.had_errors = True
        ps.streams.error = ["ConvertTo-SecureString failed"]
        return []

    t, pools = make(responder)
    with pytest.raises(RemoteScriptError, match="Session setup failed"):
        t.invoke("S", {})
    assert pools[0].closed


def test_unconfigured_transport_raises_not_configured():
    with pytest.raises(NotConfigured):
        UnconfiguredTransport().invoke("S", {})


def test_prelude_exception_closes_pool():
    def responder(ps):
        raise requests.exceptions.ConnectionError("boom")

    t, pools = make(responder)
    with pytest.raises(ConnectionFailed):
        t.invoke("S", {})
    assert pools[0].closed


def test_pool_open_failure_closes_pool():
    t, pools = make(lambda ps: [])
    orig = FakePool.open

    def bad_open(self):
        raise requests.exceptions.ConnectionError("refused")

    FakePool.open = bad_open
    try:
        with pytest.raises(ConnectionFailed):
            t.invoke("S", {})
    finally:
        FakePool.open = orig
    assert pools[0].closed


def test_unexpected_exception_is_not_reported_as_connection_failure():
    def responder(ps):
        if ps.script == "PRELUDE":
            return []
        raise KeyError("oops")

    t, _ = make(responder)
    with pytest.raises(SysadminError) as ei:
        t.invoke("S", {})
    assert not isinstance(ei.value, ConnectionFailed)
    assert ei.value.type == "Error"
    assert "KeyError" in ei.value.message


def _unreachable_transport(clock):
    opened = []

    def pool_factory(settings):
        pool = FakePool(lambda ps: [])
        opened.append(pool)

        def fail():
            raise requests.exceptions.ConnectTimeout("timed out")

        pool.open = fail
        return pool

    https = Settings(host="dc01", username="CORP\\svc", password="pw", use_https=True)
    return PsrpTransport(https, "PRELUDE", pool_factory=pool_factory, ps_factory=FakePS, clock=clock), opened


def test_failed_connect_fails_fast_during_cooldown_then_retries():
    now = [0.0]
    t, opened = _unreachable_transport(lambda: now[0])
    with pytest.raises(Timeout) as first:
        t.invoke("S", {})
    assert "Use HTTPS" in first.value.hint
    now[0] = 10.0
    with pytest.raises(Timeout):
        t.invoke("S", {})
    assert len(opened) == 1  # no second 10-second connect attempt
    now[0] = 31.0
    with pytest.raises(Timeout):
        t.invoke("S", {})
    assert len(opened) == 2


def test_successful_connect_clears_cooldown():
    calls = {"n": 0}
    now = [0.0]

    def pool_factory(settings):
        pool = FakePool(lambda ps: ["{}"] if ps.script != "PRELUDE" else [])
        calls["n"] += 1
        if calls["n"] == 1:
            def fail():
                raise requests.exceptions.ConnectionError("refused")
            pool.open = fail
        return pool

    t = PsrpTransport(SETTINGS, "PRELUDE", pool_factory=pool_factory, ps_factory=FakePS, clock=lambda: now[0])
    with pytest.raises(ConnectionFailed):
        t.invoke("S", {})
    now[0] = 31.0
    assert t.invoke("S", {}) == ["{}"]
    assert t._connect_failure is None
