"""Local transport: one persistent PowerShell child on this (domain-joined Windows) machine.

The child runs a small host loop that reads framed requests on stdin and writes framed results on stdout.
It runs either as the Hermes user (plain subprocess) or "runas /netonly" style as a chosen account
(CreateProcessWithLogonW with LOGON_NETCREDENTIALS_ONLY): the local identity stays the Hermes user and every
network authentication (LDAP, SMB, WinRM, Kerberos) uses the chosen account. The password is handed to
CreateProcessWithLogonW only; it never appears in the command line, on the child's stdin, or in logs.

Protocol (one line each way per request, ASCII):
  request  = base64(UTF-8 JSON {"script": str, "params": {...}[, "scope": "global"]}) + "\\n"
  response = <SENTINEL> + base64(UTF-8 JSON {"out": [str], "errors": [str], "terminated": bool}) + "\\n"
SENTINEL is "\\x1eHS:<random hex>:", chosen per process. Stdout lines without it (Write-Host, native tools)
are ignored. The command line carries only a tiny bootstrap (CreateProcessWithLogonW caps it at 1024
characters); the host loop itself is the first stdin line.
"""

from __future__ import annotations

import base64
import binascii
import json
import logging
import ntpath
import os
import queue
import secrets
import subprocess
import threading
import time
from contextlib import suppress
from typing import Any, Callable, Mapping

from .config import Settings
from .errors import ConnectionFailed, RemoteScriptError, SysadminError, Timeout

log = logging.getLogger(__name__)

#: Same meaning as transport.CONNECT_COOLDOWN.
CONNECT_COOLDOWN = 30.0
#: Per-invoke deadline in seconds. Fleet fan-out can take ~40 s; a hung child is killed after this.
DEFAULT_TIMEOUT = 300.0
POWERSHELL = ntpath.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
CREATE_NO_WINDOW = 0x08000000
LOGON_NETCREDENTIALS_ONLY = 2
STARTF_USESTDHANDLES = 0x100
STARTF_USESHOWWINDOW = 0x1
ERROR_LOGON_FAILURE = 1326
SETTINGS_HINT = "Set 'transport' to winrm (or auto) in the plugin settings to use a WinRM jump host instead."

HOST_LOOP = r"""
$ProgressPreference = 'SilentlyContinue'
$__hsSentinel = [string][char]0x1e + 'HS:' + $__hsTag + ':'
$__hsOut = [System.IO.StreamWriter]::new([Console]::OpenStandardOutput(), [System.Text.ASCIIEncoding]::new())
$__hsOut.AutoFlush = $true
function Global:ConvertTo-HermesHostValue {
    # ConvertFrom-Json objects -> hashtables, recursively; arrays stay arrays (even with 0 or 1 item).
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = ConvertTo-HermesHostValue $p.Value }
        return $h
    }
    if ($Value -is [System.Array]) { return ,@(foreach ($v in $Value) { ConvertTo-HermesHostValue $v }) }
    return $Value
}
while ($true) {
    $__hsLine = $__hsIn.ReadLine()
    if ($null -eq $__hsLine) { break }
    if ($__hsLine.Trim() -eq '') { continue }
    $__hsResult = New-Object System.Collections.Generic.List[string]
    $__hsTerminated = $false
    $__hsFatal = $null
    $Error.Clear()
    try {
        $__hsReq = ConvertFrom-Json ([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($__hsLine.Trim())))
        $__hsParams = @{}
        if ($null -ne $__hsReq.params) {
            foreach ($__hsP in $__hsReq.params.PSObject.Properties) { $__hsParams[$__hsP.Name] = ConvertTo-HermesHostValue $__hsP.Value }
        }
        $__hsSb = [scriptblock]::Create([string]$__hsReq.script)
        if ("$($__hsReq.scope)" -eq 'global') { $__hsItems = . $__hsSb @__hsParams } else { $__hsItems = & $__hsSb @__hsParams }
        foreach ($__hsI in @($__hsItems)) {
            if ($null -eq $__hsI) { continue }
            if ($__hsI -is [string]) { $__hsResult.Add($__hsI) } else { $__hsResult.Add(($__hsI | Out-String).Trim()) }
        }
    } catch {
        $__hsTerminated = $true
        $__hsFatal = "$($_.Exception.Message)"
    }
    $__hsErrors = New-Object System.Collections.Generic.List[string]
    $__hsAll = @($Error)
    [array]::Reverse($__hsAll)
    foreach ($__hsE in $__hsAll) { $__hsErrors.Add("$__hsE") }
    if ($__hsFatal -and -not $__hsErrors.Contains($__hsFatal)) { $__hsErrors.Add($__hsFatal) }
    $__hsJson = '{"out":[' + ((@($__hsResult) | ForEach-Object { ConvertTo-Json -InputObject ([string]$_) }) -join ',') +
        '],"errors":[' + ((@($__hsErrors) | ForEach-Object { ConvertTo-Json -InputObject ([string]$_) }) -join ',') +
        '],"terminated":' + $(if ($__hsTerminated) { 'true' } else { 'false' }) + '}'
    try {
        $__hsOut.Write("`n" + $__hsSentinel + [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($__hsJson)) + "`n")
    } catch { break }
}
"""


def bootstrap(tag: str) -> str:
    """The -EncodedCommand text: read the host loop from stdin and run it in global scope."""
    return (
        f"$__hsTag='{tag}';$__hsIn=[IO.StreamReader]::new([Console]::OpenStandardInput());"
        ". ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($__hsIn.ReadLine()))))"
    )


def build_argv(tag: str, powershell: str = POWERSHELL) -> list[str]:
    encoded = base64.b64encode(bootstrap(tag).encode("utf-16-le")).decode("ascii")
    return [powershell, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded]


def command_line(argv: list[str]) -> str:
    return subprocess.list2cmdline(argv)


def split_user(username: str) -> tuple[str, str | None]:
    """DOMAIN\\user -> (user, DOMAIN); user@domain -> (user@domain, None) as CreateProcessWithLogonW wants."""
    name = (username or "").strip()
    hint = "Set the username as DOMAIN\\user or user@domain."
    if "\\" in name:
        domain, _, user = name.partition("\\")
        if domain and user and "\\" not in user:
            return user, domain
    elif "@" in name:
        user, _, domain = name.partition("@")
        if user and domain:
            return name, None
    raise ConnectionFailed(f"Cannot run as {name or '(no username)'}: the domain is missing.", hint=hint)


def logon_error(code: int, username: str) -> ConnectionFailed:
    if code == ERROR_LOGON_FAILURE:
        return ConnectionFailed(
            f"Windows logon failed for {username}.",
            hint="Logon failed: check username/password in the plugin settings.",
        )
    try:
        text = os.strerror(code) if os.name != "nt" else _format_error(code)
    except Exception:
        text = ""
    return ConnectionFailed(
        f"Could not start PowerShell as {username} (Windows error {code}{': ' + text if text else ''}).",
        hint="Check the username and that this machine can reach a domain controller.",
    )


def _format_error(code: int) -> str:
    import ctypes

    return ctypes.FormatError(code).strip()


def popen_process(argv: list[str], settings: Settings | None = None) -> Any:
    """Child as the Hermes user. stderr goes nowhere: only the framed stdout matters."""
    return subprocess.Popen(
        argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        creationflags=CREATE_NO_WINDOW if os.name == "nt" else 0,
    )


class _LogonProcess:
    """A child started with CreateProcessWithLogonW; same surface as subprocess.Popen for this module."""

    def __init__(self, process_handle: int, pid: int, stdin: Any, stdout: Any) -> None:
        self._handle = process_handle
        self.pid = pid
        self.stdin = stdin
        self.stdout = stdout
        self.returncode: int | None = None

    def poll(self) -> int | None:
        import _winapi

        if self.returncode is None and self._handle:
            if _winapi.WaitForSingleObject(self._handle, 0) == _winapi.WAIT_OBJECT_0:
                self.returncode = _winapi.GetExitCodeProcess(self._handle)
                self._close_handle()
        return self.returncode

    def wait(self, timeout: float | None = None) -> int | None:
        import _winapi

        if self.returncode is None and self._handle:
            ms = _winapi.INFINITE if timeout is None else int(timeout * 1000)
            _winapi.WaitForSingleObject(self._handle, ms)
        return self.poll()

    def kill(self) -> None:
        import _winapi

        if self.returncode is None and self._handle:
            with suppress(OSError):
                _winapi.TerminateProcess(self._handle, 1)

    def _close_handle(self) -> None:
        import _winapi

        handle, self._handle = self._handle, 0
        if handle:
            with suppress(OSError):
                _winapi.CloseHandle(handle)

    def __del__(self) -> None:  # pragma: no cover - Windows only
        with suppress(Exception):
            self._close_handle()


def logon_process(argv: list[str], settings: Settings) -> _LogonProcess:  # pragma: no cover - Windows only
    """runas /netonly: CreateProcessWithLogonW(LOGON_NETCREDENTIALS_ONLY) with redirected std handles."""
    import _winapi
    import ctypes
    import msvcrt
    from ctypes import wintypes

    user, domain = split_user(settings.username)

    class STARTUPINFOW(ctypes.Structure):
        _fields_ = [
            ("cb", wintypes.DWORD), ("lpReserved", wintypes.LPWSTR), ("lpDesktop", wintypes.LPWSTR),
            ("lpTitle", wintypes.LPWSTR), ("dwX", wintypes.DWORD), ("dwY", wintypes.DWORD),
            ("dwXSize", wintypes.DWORD), ("dwYSize", wintypes.DWORD), ("dwXCountChars", wintypes.DWORD),
            ("dwYCountChars", wintypes.DWORD), ("dwFillAttribute", wintypes.DWORD), ("dwFlags", wintypes.DWORD),
            ("wShowWindow", wintypes.WORD), ("cbReserved2", wintypes.WORD), ("lpReserved2", ctypes.c_void_p),
            ("hStdInput", wintypes.HANDLE), ("hStdOutput", wintypes.HANDLE), ("hStdError", wintypes.HANDLE),
        ]

    class PROCESS_INFORMATION(ctypes.Structure):
        _fields_ = [
            ("hProcess", wintypes.HANDLE), ("hThread", wintypes.HANDLE),
            ("dwProcessId", wintypes.DWORD), ("dwThreadId", wintypes.DWORD),
        ]

    advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
    create = advapi32.CreateProcessWithLogonW
    create.argtypes = [
        wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.DWORD, wintypes.LPCWSTR, wintypes.LPWSTR,
        wintypes.DWORD, ctypes.c_void_p, wintypes.LPCWSTR, ctypes.POINTER(STARTUPINFOW),
        ctypes.POINTER(PROCESS_INFORMATION),
    ]
    create.restype = wintypes.BOOL

    in_r, in_w = _winapi.CreatePipe(None, 0)
    out_r, out_w = _winapi.CreatePipe(None, 0)
    nul_fd = os.open(os.devnull, os.O_WRONLY)
    child_ends = [in_r, out_w]
    try:
        nul = msvcrt.get_osfhandle(nul_fd)
        for h in (in_r, out_w, nul):
            os.set_handle_inheritable(h, True)
        si = STARTUPINFOW()
        si.cb = ctypes.sizeof(STARTUPINFOW)
        si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW
        si.wShowWindow = 0
        si.hStdInput, si.hStdOutput, si.hStdError = in_r, out_w, nul
        pi = PROCESS_INFORMATION()
        cmd = ctypes.create_unicode_buffer(command_line(argv))
        ok = create(user, domain, settings.password, LOGON_NETCREDENTIALS_ONLY, None, cmd, CREATE_NO_WINDOW,
                    None, None, ctypes.byref(si), ctypes.byref(pi))
        code = ctypes.get_last_error()
    except BaseException:
        for h in (in_w, out_r):
            with suppress(OSError):
                _winapi.CloseHandle(h)
        raise
    finally:
        # The child holds its own duplicates now; the parent must not keep the child's ends open.
        for h in child_ends:
            with suppress(OSError):
                _winapi.CloseHandle(h)
        os.close(nul_fd)
    if not ok:
        for h in (in_w, out_r):
            with suppress(OSError):
                _winapi.CloseHandle(h)
        raise logon_error(code, settings.username)
    with suppress(OSError):
        _winapi.CloseHandle(pi.hThread)
    stdin = open(msvcrt.open_osfhandle(in_w, 0), "wb", buffering=0)
    stdout = open(msvcrt.open_osfhandle(out_r, os.O_RDONLY), "rb")
    return _LogonProcess(pi.hProcess, pi.dwProcessId, stdin, stdout)


def default_process_factory(argv: list[str], settings: Settings) -> Any:
    if os.name != "nt":
        raise ConnectionFailed("The local transport needs Hermes to run on Windows.", hint=SETTINGS_HINT)
    if settings.run_as == "hermes_user":
        return popen_process(argv, settings)
    return logon_process(argv, settings)


def _encode(obj: Mapping[str, Any]) -> bytes:
    return base64.b64encode(json.dumps(obj, ensure_ascii=False, default=str).encode("utf-8")) + b"\n"


class _Child:
    """A started child plus the reader thread that turns its framed stdout lines into queue items."""

    _EOF = object()

    def __init__(self, process: Any, sentinel: bytes) -> None:
        self.process = process
        self.sentinel = sentinel
        self.results: queue.Queue = queue.Queue()
        self.reader = threading.Thread(target=self._read, name="hermes-sysadmin-local-ps", daemon=True)
        self.reader.start()

    def _read(self) -> None:
        stdout = self.process.stdout
        try:
            while True:
                line = stdout.readline()
                if not line:
                    break
                at = line.find(self.sentinel)
                if at >= 0:
                    self.results.put(line[at + len(self.sentinel):].strip())
        except Exception:  # pragma: no cover - pipe torn down under us
            log.debug("hermes-sysadmin: local PowerShell reader stopped", exc_info=True)
        finally:
            self.results.put(self._EOF)

    def send(self, data: bytes) -> None:
        self.process.stdin.write(data)
        self.process.stdin.flush()

    def alive(self) -> bool:
        try:
            return self.process.poll() is None
        except Exception:
            return False

    def kill(self) -> None:
        with suppress(Exception):
            self.process.kill()
        for pipe in (getattr(self.process, "stdin", None), getattr(self.process, "stdout", None)):
            with suppress(Exception):
                if pipe is not None:
                    pipe.close()
        with suppress(Exception):
            self.process.wait(timeout=5)


class LocalTransport:
    def __init__(
        self,
        settings: Settings,
        prelude: str,
        *,
        process_factory: Callable[[list[str], Settings], Any] | None = None,
        powershell: str = POWERSHELL,
        timeout: float = DEFAULT_TIMEOUT,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._settings = settings
        self._prelude = prelude
        self._factory = process_factory or default_process_factory
        self._powershell = powershell
        self._timeout = timeout
        self._clock = clock
        self._lock = threading.RLock()
        self._child: _Child | None = None
        self._connect_failure: tuple[float, SysadminError] | None = None

    def __repr__(self) -> str:
        return f"LocalTransport(run_as={self._settings.run_as!r}, user={self._settings.username!r})"

    @property
    def _who(self) -> str:
        if self._settings.run_as == "hermes_user":
            return "the Hermes user"
        return self._settings.username or "(no username)"

    # -- process lifecycle --------------------------------------------------------------------

    def _start(self) -> _Child:
        tag = secrets.token_hex(12)
        argv = build_argv(tag, self._powershell)
        log.info("hermes-sysadmin: starting local PowerShell (run_as=%s)", self._settings.run_as)
        try:
            process = self._factory(argv, self._settings)
        except SysadminError:
            raise
        except OSError as exc:
            raise ConnectionFailed(
                f"Could not start local PowerShell as {self._who}: {exc.strerror or type(exc).__name__}.",
                hint=f"Check that Windows PowerShell 5.1 is installed at {self._powershell}. {SETTINGS_HINT}",
            ) from None
        child = _Child(process, ("\x1eHS:" + tag + ":").encode("ascii"))
        try:
            child.send(base64.b64encode(HOST_LOOP.encode("utf-8")) + b"\n")
            out, errors, terminated = self._exchange(child, {"script": self._prelude, "params": {}, "scope": "global"})
        except BaseException:
            child.kill()
            raise
        if terminated:
            child.kill()
            message = errors[0] if errors else "prelude failed"
            raise RemoteScriptError(f"Session setup failed on this machine: {message}")
        return child

    def _drop(self) -> None:
        child, self._child = self._child, None
        if child is not None:
            child.kill()

    def _connect(self) -> None:
        failed = self._connect_failure
        if failed is not None and self._clock() - failed[0] < CONNECT_COOLDOWN:
            err = failed[1]
            raise type(err)(err.message, hint=err.hint)
        try:
            self._child = self._start()
        except (ConnectionFailed, Timeout) as err:
            self._connect_failure = (self._clock(), err)
            raise
        self._connect_failure = None

    # -- one request/response -----------------------------------------------------------------

    def _exchange(self, child: _Child, request: Mapping[str, Any]) -> tuple[list[str], list[str], bool]:
        try:
            child.send(_encode(request))
        except (OSError, ValueError) as exc:
            raise ConnectionFailed(
                f"The local PowerShell process exited unexpectedly ({type(exc).__name__}).",
                hint="It is restarted on the next call.",
            ) from None
        deadline = self._clock() + self._timeout
        while True:
            remaining = deadline - self._clock()
            try:
                item = child.results.get(timeout=max(0.0, remaining))
            except queue.Empty:
                child.kill()
                raise Timeout(f"Local PowerShell did not answer within {int(self._timeout)} s; it was stopped.") from None
            if item is _Child._EOF:
                raise ConnectionFailed(
                    "The local PowerShell process exited unexpectedly.", hint="It is restarted on the next call."
                )
            try:
                payload = json.loads(base64.b64decode(item, validate=True).decode("utf-8"))
                out = [str(o) for o in payload.get("out") or []]
                errors = [str(e) for e in payload.get("errors") or []]
                return out, errors, bool(payload.get("terminated"))
            except (binascii.Error, ValueError, UnicodeDecodeError, AttributeError):
                child.kill()
                raise ConnectionFailed(
                    "The local PowerShell process sent a malformed response.", hint="It is restarted on the next call."
                ) from None

    def invoke(self, script: str, params: Mapping[str, Any]) -> list[Any]:
        with self._lock:
            if self._child is not None and not self._child.alive():
                self._drop()
            if self._child is None:
                self._connect()
            child = self._child
            assert child is not None
            try:
                out, errors, _ = self._exchange(child, {"script": script, "params": dict(params)})
            except SysadminError:
                self._drop()
                raise
            if errors and not out:
                raise RemoteScriptError("; ".join(errors[:3]) or "unknown error")
            return list(out)

    def close(self) -> None:
        with self._lock:
            self._drop()
