from types import SimpleNamespace

import pytest
import requests

from sysadmin.config import Settings
from sysadmin.errors import ConnectionFailed, NotConfigured, RemoteScriptError, Timeout
from sysadmin.transport import PsrpTransport, UnconfiguredTransport

SETTINGS = Settings(host="dc01", username="CORP\\svc", password="pw")


class FakePool:
    def __init__(self, responder):
        self.responder = responder
        self.closed = False
        self.prelude_runs = 0

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
