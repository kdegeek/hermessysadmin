"""Local transport: one persistent PowerShell child on this (domain-joined Windows) machine.

The child runs a small host loop that reads framed requests on stdin and writes framed results on stdout.
It runs either as the Hermes user (plain subprocess) or "runas /netonly" style as a chosen account
(CreateProcessWithLogonW with LOGON_NETCREDENTIALS_ONLY): the local identity stays the Hermes user and every
network authentication (LDAP, SMB, WinRM, Kerberos) uses the chosen account. The password is handed to
LogonUserW (validated once, so a wrong password cannot lock the account out through repeated network
logons) and CreateProcessWithLogonW only; it never appears in the command line, on the child's stdin, in its
environment, or in logs.

Protocol (one line each way per request, ASCII):
  request  = base64(UTF-8 JSON {"seq": int, "script": str, "params": {...}[, "scope": "global"]}) + "\\n"
  response = <SENTINEL> + base64(UTF-8 JSON {"seq": int|null, "out": [str], "errors": [str], "terminated": bool})
SENTINEL is "\\x1eHS:<random hex>:", chosen per process. Stdout lines without it (Write-Host, native tools)
are ignored, and so are frames whose seq is not the request's. The command line carries only a tiny
bootstrap (CreateProcessWithLogonW caps it at 1024 characters); the host loop itself is the first stdin line.
The loop keeps its state in $private: variables, which scripts run with & cannot see.
"""

from __future__ import annotations

import base64
import binascii
import itertools
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
CREATE_SUSPENDED = 0x00000004
CREATE_NO_WINDOW = 0x08000000
LOGON_NETCREDENTIALS_ONLY = 2
LOGON32_LOGON_NETWORK = 3
LOGON32_PROVIDER_DEFAULT = 0
STARTF_USESTDHANDLES = 0x100
STARTF_USESHOWWINDOW = 0x1
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000
JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS = 9
ERROR_LOGON_FAILURE = 1326
#: LogonUserW results that mean "these credentials will never work"; each one latches the transport.
CREDENTIAL_ERRORS = {
    ERROR_LOGON_FAILURE: "the username or password is wrong",
    1327: "an account restriction blocks the logon",
    1328: "the account may not log on at this time of day",
    1329: "the account may not log on from this computer",
    1330: "the password has expired",
    1331: "the account is disabled",
    1793: "the account has expired",
    1907: "the password must be changed before first logon",
    1909: "the account is locked out",
}
#: The credentials are valid; network logon is only denied by policy. Not a reason to refuse.
ERROR_LOGON_TYPE_NOT_GRANTED = 1385
SETTINGS_HINT = "Set 'transport' to winrm (or auto) in the plugin settings to use a WinRM jump host instead."
NO_NETWORK_CREDENTIALS_HINT = (
    "The account Hermes runs as has no network credentials in this logon session (typical for an SSH key-auth "
    "session, a scheduled task without a stored password, or some service accounts). Choose Run as: account, "
    "or run Hermes in a password logon."
)
ACCOUNT_PROBE_HINT = (
    "The run-as account could not authenticate to a domain controller. Check the username and password in the "
    "plugin settings, that the account is enabled and not locked out, and that a domain controller is reachable."
)

#: Environment variables a PowerShell child may inherit (matched case-insensitively). Everything else,
#: notably Hermes's API keys and SYSADMIN_WINRM_PASSWORD, is withheld.
ENV_ALLOWLIST = frozenset(n.upper() for n in (
    "SystemRoot", "windir", "PATH", "PATHEXT", "PSModulePath", "TEMP", "TMP", "USERPROFILE", "USERDOMAIN",
    "USERDNSDOMAIN", "USERNAME", "COMPUTERNAME", "ProgramData", "ProgramFiles", "ProgramFiles(x86)",
    "ProgramW6432", "APPDATA", "LOCALAPPDATA", "HOMEDRIVE", "HOMEPATH", "NUMBER_OF_PROCESSORS",
    "PROCESSOR_ARCHITECTURE", "OS", "LOGONSERVER", "SystemDrive", "ALLUSERSPROFILE", "PUBLIC", "ComSpec",
    "PROCESSOR_IDENTIFIER", "PROCESSOR_LEVEL", "PROCESSOR_REVISION",
))
ENV_ALLOWED_PREFIXES = ("COMMONPROGRAMFILES", "COMMONPROGRAMW6432")


def safe_environment(environ: Mapping[str, str]) -> dict[str, str]:
    return {
        k: v for k, v in environ.items()
        if k.upper() in ENV_ALLOWLIST or k.upper().startswith(ENV_ALLOWED_PREFIXES)
    }


#: Cheap authenticated LDAP read run once after the prelude: the RootDSE is readable anonymously, the
#: domain object is not, so this fails when the process has no usable network credentials.
NETWORK_PROBE = r"""
param()
$root = [ADSI]'LDAP://RootDSE'
$nc = "$($root.defaultNamingContext)"
if (-not $nc) { throw 'No domain controller answered the RootDSE query.' }
$d = [ADSI]"LDAP://$nc"
$d.RefreshCache(@('distinguishedName'))
if (-not "$($d.distinguishedName)") { throw "Reading $nc returned nothing (the bind was not authenticated)." }
'ok'
"""

HOST_LOOP = r"""
$ProgressPreference = 'SilentlyContinue'
$private:__hsSentinel = [string][char]0x1e + 'HS:' + $__hsTag + ':'
Remove-Variable -Name __hsTag -Force
$private:__hsOut = [System.IO.StreamWriter]::new([Console]::OpenStandardOutput(), [System.Text.ASCIIEncoding]::new())
$__hsOut.AutoFlush = $true
# ConvertFrom-Json objects -> hashtables, recursively; arrays stay arrays (even with 0 or 1 item).
# A private scriptblock (not a function) so scripts cannot see it; it recurses through $Self.
$private:__hsConvert = {
    param($Value, $Self)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = & $Self $p.Value $Self }
        return $h
    }
    if ($Value -is [System.Array]) { return ,@(foreach ($v in $Value) { & $Self $v $Self }) }
    return $Value
}
foreach ($private:__hsName in @('__hsLine', '__hsResult', '__hsTerminated', '__hsFatal', '__hsReq', '__hsSeq', '__hsParams',
        '__hsP', '__hsSb', '__hsItems', '__hsI', '__hsErrors', '__hsAll', '__hsE', '__hsJson')) {
    Set-Variable -Name $__hsName -Value $null -Option Private
}
while ($true) {
    $__hsLine = $__hsIn.ReadLine()
    if ($null -eq $__hsLine) { break }
    if ($__hsLine.Trim() -eq '') { continue }
    $__hsResult = New-Object System.Collections.Generic.List[string]
    $__hsTerminated = $false
    $__hsFatal = $null
    $__hsSeq = 'null'
    $Error.Clear()
    try {
        $__hsReq = ConvertFrom-Json ([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($__hsLine.Trim())))
        if ($null -ne $__hsReq.seq) { $__hsSeq = [string][int64]$__hsReq.seq }
        $__hsParams = @{}
        if ($null -ne $__hsReq.params) {
            foreach ($__hsP in $__hsReq.params.PSObject.Properties) { $__hsParams[$__hsP.Name] = & $__hsConvert $__hsP.Value $__hsConvert }
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
    $__hsJson = '{"seq":' + $__hsSeq + ',"out":[' + ((@($__hsResult) | ForEach-Object { ConvertTo-Json -InputObject ([string]$_) }) -join ',') +
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
        f"$__hsTag='{tag}';$private:__hsIn=[IO.StreamReader]::new([Console]::OpenStandardInput());"
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


class CredentialRejected(ConnectionFailed):
    """Windows rejected the run-as credentials. The transport refuses to start again until it is rebuilt
    (a settings change rebuilds it), so a wrong password is tried once, not once per call and target."""


def logon_error(code: int, username: str) -> ConnectionFailed:
    """Map a Win32 logon error to a ConnectionFailed. Never includes the password."""
    if code in CREDENTIAL_ERRORS:
        return CredentialRejected(
            f"Windows rejected the run-as account {username}: {CREDENTIAL_ERRORS[code]} (error {code}).",
            hint="Logon failed: check username/password (and that the account is enabled, not locked out or "
                 "expired) in the plugin settings, then save. The plugin will not retry this password until the "
                 "settings change, so it cannot lock the account out.",
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


def check_credentials(settings: Settings) -> None:
    """Validate the run-as password once with a network logon (LogonUserW) before any process uses it.

    CreateProcessWithLogonW(LOGON_NETCREDENTIALS_ONLY) never checks the password, so without this a wrong one
    would fail (and count as a bad attempt) on every op and every fan-out target. No-op for hermes_user and
    off Windows.
    """
    if settings.run_as != "account" or os.name != "nt":
        return
    import ctypes  # pragma: no cover - Windows only
    from ctypes import wintypes

    user, domain = split_user(settings.username)
    advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
    logon = advapi32.LogonUserW
    logon.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                      ctypes.POINTER(wintypes.HANDLE)]
    logon.restype = wintypes.BOOL
    token = wintypes.HANDLE()
    ok = logon(user, domain, settings.password, LOGON32_LOGON_NETWORK, LOGON32_PROVIDER_DEFAULT, ctypes.byref(token))
    code = ctypes.get_last_error()
    if ok:
        ctypes.WinDLL("kernel32").CloseHandle(token)
        return
    if code == ERROR_LOGON_TYPE_NOT_GRANTED:
        return  # the password is right; only network logon to this machine is denied by policy
    raise logon_error(code, settings.username)


class _Job:  # pragma: no cover - Windows only
    """A Job object with KILL_ON_JOB_CLOSE: terminating it (or closing it) kills the child and grandchildren."""

    def __init__(self) -> None:
        import ctypes
        from ctypes import wintypes

        class IO_COUNTERS(ctypes.Structure):
            _fields_ = [(n, ctypes.c_ulonglong) for n in (
                "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
                "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]

        class BASIC(ctypes.Structure):
            _fields_ = [
                ("PerProcessUserTimeLimit", ctypes.c_int64), ("PerJobUserTimeLimit", ctypes.c_int64),
                ("LimitFlags", wintypes.DWORD), ("MinimumWorkingSetSize", ctypes.c_size_t),
                ("MaximumWorkingSetSize", ctypes.c_size_t), ("ActiveProcessLimit", wintypes.DWORD),
                ("Affinity", ctypes.c_size_t), ("PriorityClass", wintypes.DWORD), ("SchedulingClass", wintypes.DWORD),
            ]

        class EXTENDED(ctypes.Structure):
            _fields_ = [
                ("BasicLimitInformation", BASIC), ("IoInfo", IO_COUNTERS), ("ProcessMemoryLimit", ctypes.c_size_t),
                ("JobMemoryLimit", ctypes.c_size_t), ("PeakProcessMemoryUsed", ctypes.c_size_t),
                ("PeakJobMemoryUsed", ctypes.c_size_t),
            ]

        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        k32.CreateJobObjectW.restype = wintypes.HANDLE
        k32.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
        k32.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
        k32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        k32.TerminateJobObject.argtypes = [wintypes.HANDLE, wintypes.UINT]
        k32.CloseHandle.argtypes = [wintypes.HANDLE]
        self._k32 = k32
        self.handle = k32.CreateJobObjectW(None, None)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        info = EXTENDED()
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not k32.SetInformationJobObject(self.handle, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS,
                                           ctypes.byref(info), ctypes.sizeof(info)):
            err = ctypes.get_last_error()
            self.close()
            raise ctypes.WinError(err)

    def assign(self, process_handle: int) -> bool:
        ok = bool(self.handle and self._k32.AssignProcessToJobObject(self.handle, process_handle))
        if not ok:
            log.debug("hermes-sysadmin: could not put local PowerShell in a job object")
        return ok

    def terminate(self) -> None:
        if self.handle:
            self._k32.TerminateJobObject(self.handle, 1)

    def close(self) -> None:
        handle, self.handle = self.handle, None
        if handle:
            self._k32.CloseHandle(handle)


class _PopenProcess:  # pragma: no cover - Windows only
    """subprocess.Popen plus a job object, so kill() takes grandchildren (native tools) down too."""

    def __init__(self, popen: subprocess.Popen, job: Any) -> None:
        self._popen = popen
        self._job = job
        self.stdin = popen.stdin
        self.stdout = popen.stdout
        self.pid = popen.pid

    def poll(self) -> int | None:
        return self._popen.poll()

    def wait(self, timeout: float | None = None) -> int | None:
        return self._popen.wait(timeout)

    def kill(self) -> None:
        if self._job is not None:
            with suppress(OSError):
                self._job.terminate()
        with suppress(OSError):
            self._popen.kill()
        if self._job is not None:
            with suppress(OSError):
                self._job.close()


def popen_process(argv: list[str], settings: Settings | None = None) -> Any:
    """Child as the Hermes user, with an allowlisted environment (no Hermes secrets). stderr goes nowhere."""
    popen = subprocess.Popen(
        argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        env=safe_environment(os.environ),
        creationflags=CREATE_NO_WINDOW if os.name == "nt" else 0,
    )
    if os.name != "nt":
        return popen
    job = None  # pragma: no cover - Windows only
    try:
        job = _Job()
        job.assign(int(popen._handle))  # type: ignore[attr-defined]
    except OSError:
        log.debug("hermes-sysadmin: job object unavailable for local PowerShell", exc_info=True)
    return _PopenProcess(popen, job)


class _LogonProcess:  # pragma: no cover - Windows only
    """A child started with CreateProcessWithLogonW; same surface as subprocess.Popen for this module."""

    def __init__(self, process_handle: int, pid: int, stdin: Any, stdout: Any, job: Any = None) -> None:
        self._handle = process_handle
        self._job = job
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

        if self._job is not None:
            with suppress(OSError):
                self._job.terminate()
        if self.returncode is None and self._handle:
            with suppress(OSError):
                _winapi.TerminateProcess(self._handle, 1)
        if self._job is not None:
            with suppress(OSError):
                self._job.close()

    def _close_handle(self) -> None:
        import _winapi

        handle, self._handle = self._handle, 0
        if handle:
            with suppress(OSError):
                _winapi.CloseHandle(handle)

    def __del__(self) -> None:
        with suppress(Exception):
            self._close_handle()


def logon_process(argv: list[str], settings: Settings) -> _LogonProcess:  # pragma: no cover - Windows only
    """runas /netonly: CreateProcessWithLogonW(LOGON_NETCREDENTIALS_ONLY) with redirected std handles.

    The process is created suspended, put in a kill-on-close job object, then resumed, so a kill on timeout
    also ends any native tool it started (which would otherwise keep our stdout pipe open).
    """
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
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.ResumeThread.argtypes = [wintypes.HANDLE]
    kernel32.ResumeThread.restype = wintypes.DWORD
    create = advapi32.CreateProcessWithLogonW
    create.argtypes = [
        wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.DWORD, wintypes.LPCWSTR, wintypes.LPWSTR,
        wintypes.DWORD, ctypes.c_void_p, wintypes.LPCWSTR, ctypes.POINTER(STARTUPINFOW),
        ctypes.POINTER(PROCESS_INFORMATION),
    ]
    create.restype = wintypes.BOOL

    def close(*handles: Any) -> None:
        for h in handles:
            if h:
                with suppress(OSError):
                    _winapi.CloseHandle(int(h))

    in_r, in_w = _winapi.CreatePipe(None, 0)
    out_r, out_w = _winapi.CreatePipe(None, 0)
    nul_fd = os.open(os.devnull, os.O_WRONLY)
    pi = PROCESS_INFORMATION()
    try:
        nul = msvcrt.get_osfhandle(nul_fd)
        for h in (in_r, out_w, nul):
            os.set_handle_inheritable(h, True)
        si = STARTUPINFOW()
        si.cb = ctypes.sizeof(STARTUPINFOW)
        si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW
        si.wShowWindow = 0
        si.hStdInput, si.hStdOutput, si.hStdError = in_r, out_w, nul
        cmd = ctypes.create_unicode_buffer(command_line(argv))
        # lpEnvironment stays NULL on purpose: per the CreateProcessWithLogonW docs the new process then gets an
        # environment created from the user's profile by the secondary logon service, not a copy of Hermes's
        # process environment, so Hermes secrets held in its environment are not passed on.
        ok = create(user, domain, settings.password, LOGON_NETCREDENTIALS_ONLY, None, cmd,
                    CREATE_NO_WINDOW | CREATE_SUSPENDED, None, None, ctypes.byref(si), ctypes.byref(pi))
        code = ctypes.get_last_error()
    except BaseException:
        close(in_w, out_r)
        raise
    finally:
        # The child holds its own duplicates now; the parent must not keep the child's ends open.
        close(in_r, out_w)
        os.close(nul_fd)
    if not ok:
        close(in_w, out_r)
        raise logon_error(code, settings.username)
    job = None
    stdin = stdout = None
    try:
        try:
            job = _Job()
            job.assign(int(pi.hProcess))
        except OSError:
            log.debug("hermes-sysadmin: job object unavailable for local PowerShell", exc_info=True)
        if kernel32.ResumeThread(pi.hThread) == 0xFFFFFFFF:
            raise ctypes.WinError(ctypes.get_last_error())
        close(pi.hThread)
        pi.hThread = None
        stdin = open(msvcrt.open_osfhandle(in_w, 0), "wb", buffering=0)
        in_w = None
        stdout = open(msvcrt.open_osfhandle(out_r, os.O_RDONLY), "rb")
        out_r = None
        return _LogonProcess(int(pi.hProcess), pi.dwProcessId, stdin, stdout, job)
    except BaseException:
        # Created but not wrapped: do not leave a suspended or orphaned child, or any handle, behind.
        if job is not None:
            with suppress(OSError):
                job.terminate()
            with suppress(OSError):
                job.close()
        with suppress(OSError):
            _winapi.TerminateProcess(int(pi.hProcess), 1)
        for f in (stdin, stdout):
            if f is not None:
                with suppress(OSError):
                    f.close()
        close(pi.hThread, pi.hProcess, in_w, out_r)
        raise


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
            # Only the reader closes stdout: closing it from another thread while readline() holds the
            # buffer lock would block that thread (and the transport lock) until a grandchild lets go.
            with suppress(Exception):
                stdout.close()

    def send(self, data: bytes) -> None:
        self.process.stdin.write(data)
        self.process.stdin.flush()

    def alive(self) -> bool:
        try:
            return self.process.poll() is None
        except Exception:
            return False

    def kill(self) -> None:
        """Never blocks for long: kill (the job, on Windows), close stdin, wait briefly. stdout is left to the reader."""
        with suppress(Exception):
            self.process.kill()
        with suppress(Exception):
            stdin = getattr(self.process, "stdin", None)
            if stdin is not None:
                stdin.close()
        with suppress(Exception):
            self.process.wait(timeout=2)




class LocalTransport:
    def __init__(
        self,
        settings: Settings,
        prelude: str,
        *,
        process_factory: Callable[[list[str], Settings], Any] | None = None,
        credential_check: Callable[[Settings], None] | None = check_credentials,
        network_probe: str | None = NETWORK_PROBE,
        powershell: str = POWERSHELL,
        timeout: float = DEFAULT_TIMEOUT,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._settings = settings
        self._prelude = prelude
        self._factory = process_factory or default_process_factory
        self._credential_check = credential_check
        self._credentials_ok = False
        self._rejected: CredentialRejected | None = None
        self._probe = network_probe
        self._powershell = powershell
        self._timeout = timeout
        self._clock = clock
        self._seq = itertools.count(1)
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

    def _check_credentials(self) -> None:
        if self._rejected is not None:
            raise CredentialRejected(self._rejected.message, hint=self._rejected.hint)
        if self._credentials_ok or self._credential_check is None:
            return
        try:
            self._credential_check(self._settings)
        except CredentialRejected as err:
            self._rejected = err
            log.warning("hermes-sysadmin: run-as credentials rejected; local transport disabled until settings change")
            raise
        self._credentials_ok = True

    def _start(self) -> _Child:
        self._check_credentials()
        tag = secrets.token_hex(12)
        argv = build_argv(tag, self._powershell)
        log.info("hermes-sysadmin: starting local PowerShell (run_as=%s)", self._settings.run_as)
        try:
            process = self._factory(argv, self._settings)
        except CredentialRejected as err:
            self._rejected = err
            raise
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
            if terminated:
                message = errors[0] if errors else "prelude failed"
                raise RemoteScriptError(f"Session setup failed on this machine: {message}")
            if self._probe:
                out, errors, terminated = self._exchange(child, {"script": self._probe, "params": {}})
                if terminated or (errors and not out):
                    # The password may have changed in AD since it was checked: re-validate on the next start.
                    self._credentials_ok = False
                    reset = getattr(self._credential_check, "invalidate", None)
                    if reset is not None:
                        reset()  # a check shared by a pool re-validates on any member's next start
                    raise self._probe_error(errors)
        except BaseException:
            child.kill()
            raise
        return child

    def _probe_error(self, errors: list[str]) -> ConnectionFailed:
        detail = (errors[0] if errors else "no detail").strip().rstrip(".")
        if self._settings.run_as == "hermes_user":
            return ConnectionFailed(
                f"The local PowerShell (as the Hermes user) could not authenticate to the domain: {detail}.",
                hint=NO_NETWORK_CREDENTIALS_HINT,
            )
        return ConnectionFailed(
            f"The local PowerShell (as {self._who}) could not authenticate to the domain: {detail}.",
            hint=ACCOUNT_PROBE_HINT,
        )

    def _drop(self) -> None:
        child, self._child = self._child, None
        if child is not None:
            child.kill()

    def _connect(self) -> None:
        if self._rejected is not None:
            raise CredentialRejected(self._rejected.message, hint=self._rejected.hint)
        failed = self._connect_failure
        if failed is not None and self._clock() - failed[0] < CONNECT_COOLDOWN:
            err = failed[1]
            raise type(err)(err.message, hint=err.hint)
        try:
            self._child = self._start()
        except CredentialRejected:
            raise
        except (ConnectionFailed, Timeout) as err:
            self._connect_failure = (self._clock(), err)
            raise
        self._connect_failure = None

    # -- one request/response -----------------------------------------------------------------

    def _exchange(self, child: _Child, request: Mapping[str, Any]) -> tuple[list[str], list[str], bool]:
        seq = next(self._seq)
        try:
            child.send(_encode({"seq": seq, **request}))
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
                got = payload.get("seq")
                if got is not None and got != seq:
                    log.debug("hermes-sysadmin: dropped a stale local PowerShell frame (seq %s, want %s)", got, seq)
                    continue
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
