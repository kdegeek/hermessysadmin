import threading
import time

import pytest

from sysadmin.config import Settings
from sysadmin.local_transport import CredentialRejected
from sysadmin.transport_pool import SharedCredentialCheck, TransportPool


class _Slow:
    made = 0

    def __init__(self):
        _Slow.made += 1
        self.closed = False

    def invoke(self, script, params):
        time.sleep(float(params.get("sleep", 0)))
        return [script]

    def close(self):
        self.closed = True


def test_pool_runs_calls_in_parallel_up_to_its_size():
    _Slow.made = 0
    pool = TransportPool(_Slow, 3)
    out = []
    threads = [threading.Thread(target=lambda i=i: out.append(pool.invoke(f"s{i}", {"sleep": 0.3}))) for i in range(3)]
    t0 = time.monotonic()
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert time.monotonic() - t0 < 0.6  # three 0.3 s calls overlapped
    assert _Slow.made == 3 and len(out) == 3


def test_pool_reuses_idle_members_and_never_exceeds_its_size():
    _Slow.made = 0
    pool = TransportPool(_Slow, 2)
    for i in range(5):
        assert pool.invoke(f"s{i}", {}) == [f"s{i}"]
    assert _Slow.made == 1  # sequential calls reuse one member
    threads = [threading.Thread(target=lambda: pool.invoke("x", {"sleep": 0.1})) for _ in range(6)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert _Slow.made == 2


def test_pool_close_closes_every_member():
    pool = TransportPool(_Slow, 2)
    pool.invoke("a", {})
    members = pool.members
    pool.close()
    assert all(m.closed for m in members)
    with pytest.raises(RuntimeError):
        pool.invoke("a", {})


def test_shared_check_validates_once_and_latches_a_rejection():
    calls = []

    def ok(settings):
        calls.append(1)

    check = SharedCredentialCheck(ok)
    for _ in range(4):
        check(Settings())
    assert len(calls) == 1
    check.invalidate()
    check(Settings())
    assert len(calls) == 2

    def bad(settings):
        calls.append(1)
        raise CredentialRejected("wrong password", hint="h")

    calls.clear()
    check = SharedCredentialCheck(bad)
    for _ in range(3):
        with pytest.raises(CredentialRejected):
            check(Settings())
    assert len(calls) == 1  # one failed logon for the whole pool, never one per process
