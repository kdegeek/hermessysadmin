"""LocalTransport: a persistent local PowerShell child speaking a framed line protocol.

The fake child below speaks the same protocol as the real host loop, so these tests pin the parent side.
tests/test_local_host_loop.py runs the real host loop under pwsh.
"""

import base64
import json
import logging
import queue
import threading
import time

import pytest

from sysadmin import local_transport as lt
from sysadmin.config import Settings
from sysadmin.errors import ConnectionFailed, RemoteScriptError, Timeout
from sysadmin.local_transport import LocalTransport

SECRET = "pw-Sup3r-secret"
ACCOUNT = Settings(transport="local", run_as="account", username="CORP\\svc", password=SECRET)
HERMES_USER = Settings(transport="local", run_as="hermes_user")


class _Stdout:
    def __init__(self):
        self.q: queue.Queue = queue.Queue()

    def readline(self):
        return self.q.get()

    def close(self):
        self.q.put(b"")


class _Stdin:
    def __init__(self, child):
        self.child = child
        self.buf = b""
        self.closed = False

    def write(self, data):
        if self.closed or self.child.dead:
            raise BrokenPipeError("child is gone")
        self.buf += data
        while b"\n" in self.buf:
            line, self.buf = self.buf.split(b"\n", 1)
            self.child.on_line(line)
        return len(data)

    def flush(self):
        pass

    def close(self):
        self.closed = True


class FakeChild:
    """Decodes requests like the host loop; `respond(req)` returns (out, errors[, terminated]) or None to hang."""

    def __init__(self, argv, respond):
        self.argv = argv
        self.respond = respond
        self.stdout = _Stdout()
        self.stdin = _Stdin(self)
        self.dead = False
        self.killed = False
        self.loop_script = None
        self.requests = []
        self.raw_lines = []
        self.tag = _tag_from_argv(argv)

    @property
    def sentinel(self):
        return ("\x1eHS:" + self.tag + ":").encode()

    def on_line(self, line):
        self.raw_lines.append(line)
        if self.loop_script is None:
            self.loop_script = base64.b64decode(line).decode("utf-8")
            return
        req = json.loads(base64.b64decode(line).decode("utf-8"))
        self.requests.append(req)
        result = self.respond(req, self)
        if result is None:
            return
        out, errors, *rest = result
        payload = {"out": out, "errors": errors, "terminated": bool(rest and rest[0])}
        self.emit(b"stray Write-Host noise\n")
        self.emit(b"\n" + self.sentinel + base64.b64encode(json.dumps(payload).encode()) + b"\n")

    def emit(self, data):
        for part in data.splitlines(keepends=True):
            self.stdout.q.put(part)

    def crash(self):
        self.dead = True
        self.stdout.q.put(b"")

    def kill(self):
        self.killed = True
        self.crash()

    def poll(self):
        return 1 if self.dead else None

    def wait(self, timeout=None):
        return 1


def _tag_from_argv(argv):
    boot = base64.b64decode(argv[-1]).decode("utf-16-le")
    return boot.split("$__hsTag='", 1)[1].split("'", 1)[0]


def make(respond, settings=ACCOUNT, **kw):
    children = []
    calls = []

    def factory(argv, s):
        calls.append(argv)
        child = FakeChild(argv, respond)
        children.append(child)
        return child

    t = LocalTransport(settings, "PRELUDE", process_factory=factory, **kw)
    return t, children, calls


def ok(req, child):
    if req["script"] == "PRELUDE":
        return [], []
    return ['{"ok":true}'], []


def test_prelude_runs_once_in_global_scope_without_credentials():
    t, children, _ = make(ok)
    assert t.invoke("SCRIPT", {"Identity": "bob"}) == ['{"ok":true}']
    assert t.invoke("SCRIPT", {"Identity": "amy"}) == ['{"ok":true}']
    assert len(children) == 1
    reqs = children[0].requests
    assert reqs[0] == {"script": "PRELUDE", "params": {}, "scope": "global"}
    assert reqs[1] == {"script": "SCRIPT", "params": {"Identity": "bob"}}
    assert reqs[2]["params"] == {"Identity": "amy"}


def test_command_line_shape_and_size():
    t, children, calls = make(ok)
    t.invoke("S", {})
    argv = calls[0]
    assert argv[1:-1] == ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand"]
    assert argv[0].lower().endswith("powershell.exe")
    # CreateProcessWithLogonW caps lpCommandLine at 1024 characters.
    assert len(lt.command_line(argv)) < 1024
    assert "while" in children[0].loop_script and "$__hsIn" in children[0].loop_script


def test_sentinel_is_random_per_process():
    t, children, _ = make(ok)
    t.invoke("S", {})
    t.close()
    t.invoke("S", {})
    assert len(children) == 2
    assert children[0].tag != children[1].tag and len(children[0].tag) >= 16


def test_stray_output_and_foreign_lines_are_ignored():
    def respond(req, child):
        if req["script"] == "PRELUDE":
            return [], []
        child.emit(b"a line that mentions HS: but has no sentinel\n")
        child.emit(b"partial Write-Host -NoNewline text")  # sentinel line arrives glued to stray text
        child.stdout.q.put(child.sentinel + base64.b64encode(json.dumps({"out": ["x", "{}"], "errors": []}).encode()) + b"\n")
        return None

    t, _, _ = make(respond)
    assert t.invoke("S", {}) == ["x", "{}"]


def test_errors_without_output_raise_remote_script_error_with_first_three():
    def respond(req, child):
        if req["script"] == "PRELUDE":
            return [], []
        return [], ["e1 Get-ADUser", "e2", "e3", "e4"]

    t, _, _ = make(respond)
    with pytest.raises(RemoteScriptError) as ei:
        t.invoke("S", {})
    assert ei.value.message == "e1 Get-ADUser; e2; e3"


def test_errors_with_output_return_output():
    def respond(req, child):
        if req["script"] == "PRELUDE":
            return [], []
        return ['{"ok":true}'], ["non-terminating"]

    t, _, _ = make(respond)
    assert t.invoke("S", {}) == ['{"ok":true}']


def test_prelude_terminating_failure_raises_and_kills_child():
    def respond(req, child):
        return [], ["Import failed"], True

    t, children, _ = make(respond)
    with pytest.raises(RemoteScriptError, match="Session setup failed.*Import failed"):
        t.invoke("S", {})
    assert children[0].killed


def test_prelude_non_terminating_errors_are_tolerated():
    def respond(req, child):
        if req["script"] == "PRELUDE":
            return [], ["module not found (SilentlyContinue)"]
        return ["{}"], []

    t, _, _ = make(respond)
    assert t.invoke("S", {}) == ["{}"]


def test_timeout_kills_child_raises_and_next_call_restarts():
    def respond(req, child):
        if req["script"] == "PRELUDE":
            return [], []
        if req["params"].get("hang"):
            return None
        return ["{}"], []

    t, children, _ = make(respond, timeout=0.3)
    started = time.monotonic()
    with pytest.raises(Timeout):
        t.invoke("S", {"hang": True})
    assert time.monotonic() - started < 3
    assert children[0].killed
    assert t.invoke("S", {}) == ["{}"]
    assert len(children) == 2


def test_crash_mid_call_raises_connection_failed_and_restarts():
    def respond(req, child):
        if req["script"] == "PRELUDE":
            return [], []
        if req["params"].get("crash"):
            child.crash()
            return None
        return ["{}"], []

    t, children, _ = make(respond)
    with pytest.raises(ConnectionFailed, match="exited"):
        t.invoke("S", {"crash": True})
    assert t.invoke("S", {}) == ["{}"]
    assert len(children) == 2


def test_dead_child_between_calls_is_restarted():
    t, children, _ = make(ok)
    t.invoke("S", {})
    children[0].crash()
    assert t.invoke("S", {}) == ['{"ok":true}']
    assert len(children) == 2


def test_malformed_frame_is_a_connection_failure():
    def respond(req, child):
        if req["script"] == "PRELUDE":
            return [], []
        child.stdout.q.put(child.sentinel + b"!!!not-base64!!!\n")
        return None

    t, children, _ = make(respond)
    with pytest.raises(ConnectionFailed, match="malformed"):
        t.invoke("S", {})
    assert children[0].killed


def test_start_failure_maps_and_cools_down():
    now = [0.0]
    attempts = []

    def factory(argv, s):
        attempts.append(1)
        raise OSError(2, "The system cannot find the file specified")

    t = LocalTransport(ACCOUNT, "PRELUDE", process_factory=factory, clock=lambda: now[0])
    with pytest.raises(ConnectionFailed):
        t.invoke("S", {})
    now[0] = 10.0
    with pytest.raises(ConnectionFailed):
        t.invoke("S", {})
    assert len(attempts) == 1
    now[0] = 40.0
    with pytest.raises(ConnectionFailed):
        t.invoke("S", {})
    assert len(attempts) == 2


def test_factory_connection_failed_passes_through_with_hint():
    def factory(argv, s):
        raise ConnectionFailed("Logon failed for CORP\\svc.", hint="check username/password")

    t = LocalTransport(ACCOUNT, "PRELUDE", process_factory=factory)
    with pytest.raises(ConnectionFailed) as ei:
        t.invoke("S", {})
    assert ei.value.hint == "check username/password"


def test_password_never_in_argv_log_stdin_or_errors(caplog):
    caplog.set_level(logging.DEBUG)

    def respond(req, child):
        if req["script"] == "PRELUDE":
            return [], []
        return [], ["boom"]

    t, children, calls = make(respond)
    with pytest.raises(RemoteScriptError) as ei:
        t.invoke("S", {"x": 1})
    t.close()
    assert SECRET not in " ".join(calls[0])
    assert SECRET not in lt.command_line(calls[0])
    assert SECRET not in base64.b64decode(calls[0][-1]).decode("utf-16-le")
    assert SECRET not in caplog.text
    assert SECRET not in str(ei.value) and SECRET not in (ei.value.hint or "")
    for raw in children[0].raw_lines:
        assert SECRET not in base64.b64decode(raw).decode("utf-8")
    assert SECRET not in repr(t)


def test_invocations_are_serialized():
    active = {"n": 0, "max": 0}
    lock = threading.Lock()

    def respond(req, child):
        if req["script"] == "PRELUDE":
            return [], []

        def later():
            time.sleep(0.05)
            with lock:
                active["n"] -= 1
            child.emit(b"\n" + child.sentinel + base64.b64encode(json.dumps({"out": ["{}"], "errors": []}).encode()) + b"\n")

        with lock:
            active["n"] += 1
            active["max"] = max(active["max"], active["n"])
        threading.Thread(target=later).start()
        return None

    t, _, _ = make(respond)
    threads = [threading.Thread(target=lambda: t.invoke("S", {})) for _ in range(5)]
    for th in threads:
        th.start()
    for th in threads:
        th.join(5)
    assert active["max"] == 1


def test_close_kills_child_and_is_idempotent():
    t, children, _ = make(ok)
    t.invoke("S", {})
    t.close()
    t.close()
    assert children[0].killed


@pytest.mark.parametrize("user,expected", [
    ("CORP\\svc", ("svc", "CORP")),
    ("svc@corp.example.local", ("svc@corp.example.local", None)),
    (" CORP\\svc ", ("svc", "CORP")),
])
def test_split_user(user, expected):
    assert lt.split_user(user) == expected


@pytest.mark.parametrize("user", ["svc", "", "\\svc", "CORP\\", "@corp"])
def test_split_user_rejects_ambiguous_names(user):
    with pytest.raises(ConnectionFailed) as ei:
        lt.split_user(user)
    assert "DOMAIN\\user or user@domain" in ei.value.hint


def test_default_factory_needs_windows(monkeypatch):
    monkeypatch.setattr(lt.os, "name", "posix")
    with pytest.raises(ConnectionFailed) as ei:
        lt.default_process_factory(["powershell.exe"], HERMES_USER)
    assert "Windows" in ei.value.message
    assert "winrm" in ei.value.hint


def test_logon_error_message_never_contains_password():
    err = lt.logon_error(1326, "CORP\\svc")
    assert "logon failed" in err.message.lower() and "username/password" in err.hint
    assert SECRET not in err.message
    other = lt.logon_error(5, "CORP\\svc")
    assert isinstance(other, ConnectionFailed) and "5" in other.message
