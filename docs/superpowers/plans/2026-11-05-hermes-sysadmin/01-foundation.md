# Phase 1 — Foundation (core library)

> Part of the [Hermes Sysadmin plan](README.md). Read the README's Global Constraints and Shared Interfaces first.

**Deliverable:** `sysadmin/` core library — errors, config, transport, runner, registry, policy, audit, service, runtime — with a passing unit test suite that needs no Windows host and no Hermes install.

---

### Task 1: Dev environment, package skeleton, errors

**Files:**
- Create: `.gitignore`, `pytest.ini`, `requirements-dev.txt`, `sysadmin/__init__.py`, `sysadmin/errors.py`, `tests/conftest.py`
- Test: `tests/test_errors.py`

**Interfaces:**
- Produces: `PLUGIN_ID`, `__version__`; all error classes, `ERROR_TYPES`, `error_result()` (see README).

- [ ] **Step 1: Create the dev environment files**

`.gitignore`:
```gitignore
.venv/
__pycache__/
*.pyc
.pytest_cache/
*.egg-info/
docs/screenshots/_tmp/
```

`pytest.ini`:
```ini
[pytest]
testpaths = tests
pythonpath = .
addopts = -q
markers =
    live: requires SYSADMIN_LIVE=1 and a reachable domain
```

`requirements-dev.txt`:
```text
pypsrp>=0.8.1,<0.9
pytest>=8,<9
fastapi>=0.110,<1
httpx>=0.27,<1
pyyaml>=6,<7
```

Run:
```bash
uv venv --python 3.11 .venv
uv pip install -p .venv -r requirements-dev.txt
.venv/bin/python -c "import pypsrp, fastapi; print('ok')"
```
Expected: `ok`

`sysadmin/__init__.py`:
```python
"""Core library for the hermes-sysadmin plugin.

Nothing in this package imports Hermes at module load, so it can be unit-tested
without a Hermes install and imported by the dashboard backend by path.
"""

PLUGIN_ID = "hermes-sysadmin"
__version__ = "0.1.0"
```

`tests/conftest.py` (initial version; extended in Task 8):
```python
"""Shared test fixtures for hermes-sysadmin."""
```

- [ ] **Step 2: Write the failing test** — `tests/test_errors.py`

```python
from sysadmin.errors import (
    ERROR_TYPES,
    ConnectionFailed,
    NotFound,
    PermissionDenied,
    error_result,
)


def test_error_result_includes_type_message_hint_and_non_empty_details():
    result = error_result(NotFound("No user bob", target="bob", category=""))
    assert result == {
        "ok": False,
        "error": {
            "type": "NotFound",
            "message": "No user bob",
            "hint": NotFound.default_hint,
            "target": "bob",
        },
    }


def test_custom_hint_overrides_default():
    assert PermissionDenied("x", hint="ask Ada").to_dict()["hint"] == "ask Ada"


def test_unknown_exception_becomes_internal_error():
    result = error_result(ValueError("boom"))
    assert result["ok"] is False
    assert result["error"]["type"] == "InternalError"
    assert "boom" in result["error"]["message"]


def test_error_types_are_indexed_by_type_string():
    assert ERROR_TYPES["NotFound"] is NotFound
    assert ERROR_TYPES["ConnectionError"] is ConnectionFailed
    assert set(ERROR_TYPES) == {
        "NotConfigured", "ConnectionError", "PermissionDenied", "NotFound", "PolicyBlocked",
        "ApprovalRequired", "RemoteScriptError", "Timeout", "InvalidArguments",
    }
```

- [ ] **Step 3: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_errors.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'sysadmin.errors'`

- [ ] **Step 4: Implement** — `sysadmin/errors.py`

```python
"""Typed errors. Every failure a tool or API route reports is one of these."""

from __future__ import annotations

from typing import Any


class SysadminError(Exception):
    type = "Error"
    default_hint = ""

    def __init__(self, message: str, *, hint: str | None = None, **details: Any) -> None:
        super().__init__(message)
        self.message = message
        self.hint = self.default_hint if hint is None else hint
        self.details = {k: v for k, v in details.items() if v not in (None, "")}

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {"type": self.type, "message": self.message, "hint": self.hint}
        out.update(self.details)
        return out


class NotConfigured(SysadminError):
    type = "NotConfigured"
    default_hint = (
        "Open Settings → Plugins → hermes-sysadmin and set the jump host, username and password."
    )


class ConnectionFailed(SysadminError):
    type = "ConnectionError"
    default_hint = (
        "Check the jump host name, port and HTTPS setting, and that WinRM is listening "
        "(run Test-WSMan on the host)."
    )


class PermissionDenied(SysadminError):
    type = "PermissionDenied"
    default_hint = (
        "The service account lacks rights for this. Delegate the permission on the OU, "
        "or use an account with the right role."
    )


class NotFound(SysadminError):
    type = "NotFound"
    default_hint = "Check the name. Use ad_search to find the exact sAMAccountName or distinguished name."


class PolicyBlocked(SysadminError):
    type = "PolicyBlocked"
    default_hint = "This is blocked by the hermes-sysadmin safety policy and cannot be approved."


class ApprovalRequired(SysadminError):
    type = "ApprovalRequired"
    default_hint = (
        "This change needs interactive approval. Headless runs (cron, single-query) cannot approve writes."
    )


class RemoteScriptError(SysadminError):
    type = "RemoteScriptError"
    default_hint = "PowerShell reported an error on the jump host; see the message and category."


class Timeout(SysadminError):
    type = "Timeout"
    default_hint = "The jump host did not answer in time. Retry, or check that the target server is online."


class InvalidArguments(SysadminError):
    type = "InvalidArguments"
    default_hint = "Fix the arguments and call the tool again."


ERROR_TYPES: dict[str, type[SysadminError]] = {
    cls.type: cls
    for cls in (
        NotConfigured, ConnectionFailed, PermissionDenied, NotFound, PolicyBlocked,
        ApprovalRequired, RemoteScriptError, Timeout, InvalidArguments,
    )
}


def error_result(exc: BaseException) -> dict[str, Any]:
    if isinstance(exc, SysadminError):
        return {"ok": False, "error": exc.to_dict()}
    return {
        "ok": False,
        "error": {
            "type": "InternalError",
            "message": f"{type(exc).__name__}: {exc}",
            "hint": "Unexpected plugin error; check ~/.hermes/logs/errors.log.",
        },
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `.venv/bin/pytest tests/test_errors.py`
Expected: `4 passed`

- [ ] **Step 6: Commit**

```bash
git add .gitignore pytest.ini requirements-dev.txt sysadmin/__init__.py sysadmin/errors.py tests/conftest.py tests/test_errors.py
git commit -m "feat: package skeleton and typed errors

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Settings

**Files:**
- Create: `sysadmin/config.py`
- Test: `tests/test_config.py`

**Interfaces:**
- Consumes: `PLUGIN_ID`.
- Produces: `Settings`, `settings_from(raw, password)`, `load_settings()`, `PASSWORD_ENV = "SYSADMIN_WINRM_PASSWORD"`, `MODES`, `AUTHS`.

- [ ] **Step 1: Write the failing test** — `tests/test_config.py`

```python
from sysadmin import config
from sysadmin.config import Settings, load_settings, settings_from


def test_defaults_when_empty():
    s = settings_from({}, "")
    assert s == Settings()
    assert not s.configured


def test_parses_and_coerces_values():
    s = settings_from(
        {
            "host": " dc01.corp.local ",
            "port": "5985",
            "use_https": "false",
            "auth": "KERBEROS",
            "username": "CORP\\svc",
            "mode": "permissive",
            "protected_objects": "svc-sql, ceo\n",
            "privileged_groups": ["Tier0"],
            "backup_stale_days": "3",
            "enable_powershell_escape": "yes",
            "verify_tls": False,
            "server_search_base": "OU=Servers,DC=corp,DC=local",
        },
        "pw",
    )
    assert s.host == "dc01.corp.local"
    assert s.port == 5985 and s.use_https is False and s.auth == "kerberos"
    assert s.mode == "permissive"
    assert s.protected_objects == ("svc-sql", "ceo")
    assert s.privileged_groups == ("Tier0",)
    assert s.backup_stale_days == 3
    assert s.enable_powershell_escape is True and s.verify_tls is False
    assert s.server_search_base == "OU=Servers,DC=corp,DC=local"
    assert s.configured


def test_invalid_values_fall_back_to_defaults():
    s = settings_from({"port": "99999", "mode": "yolo", "auth": "basic", "backup_stale_days": "-1"}, "")
    assert (s.port, s.mode, s.auth, s.backup_stale_days) == (5986, "strict", "ntlm", 7)


def test_http_default_port_is_5985():
    assert settings_from({"use_https": False}, "").port == 5985


def test_password_not_in_repr():
    assert "hunter2" not in repr(settings_from({}, "hunter2"))


def test_load_settings_without_hermes_returns_defaults(monkeypatch):
    monkeypatch.setattr(config, "_plugin_settings", lambda: {"host": "dc01"})
    monkeypatch.setattr(config, "_password", lambda: "pw")
    s = load_settings()
    assert s.host == "dc01" and s.password == "pw"


def test_load_settings_never_raises(monkeypatch):
    def boom():
        raise RuntimeError("config broken")

    monkeypatch.setattr(config, "_plugin_settings", boom)
    assert load_settings() == Settings()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_config.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'sysadmin.config'`

- [ ] **Step 3: Implement** — `sysadmin/config.py`

```python
"""Plugin settings: read from config.yaml (plugins.entries.hermes-sysadmin.settings) and Hermes secrets."""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any, Mapping

from . import PLUGIN_ID

log = logging.getLogger(__name__)

PASSWORD_ENV = "SYSADMIN_WINRM_PASSWORD"
MODES = ("strict", "permissive", "read-only")
AUTHS = ("ntlm", "kerberos")


@dataclass(frozen=True)
class Settings:
    host: str = ""
    port: int = 5986
    use_https: bool = True
    auth: str = "ntlm"
    username: str = ""
    password: str = field(default="", repr=False)
    verify_tls: bool = True
    server_search_base: str = ""
    backup_stale_days: int = 7
    mode: str = "strict"
    protected_objects: tuple[str, ...] = ()
    privileged_groups: tuple[str, ...] = ()
    enable_powershell_escape: bool = False

    @property
    def configured(self) -> bool:
        return bool(self.host and self.username and self.password)


def _bool(value: Any, default: bool) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        text = value.strip().lower()
        if text in ("true", "1", "yes", "on"):
            return True
        if text in ("false", "0", "no", "off"):
            return False
    if isinstance(value, int):
        return bool(value)
    return default


def _int(value: Any, default: int, lo: int, hi: int) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError):
        return default
    return number if lo <= number <= hi else default


def _choice(value: Any, choices: tuple[str, ...], default: str) -> str:
    text = str(value or "").strip().lower()
    return text if text in choices else default


def _strings(value: Any) -> tuple[str, ...]:
    if isinstance(value, str):
        items = value.replace("\n", ",").split(",")
    elif isinstance(value, (list, tuple)):
        items = [str(v) for v in value]
    else:
        items = []
    return tuple(s.strip() for s in items if s and s.strip())


def settings_from(raw: Mapping[str, Any] | None, password: str) -> Settings:
    raw = raw or {}
    use_https = _bool(raw.get("use_https"), True)
    return Settings(
        host=str(raw.get("host") or "").strip(),
        port=_int(raw.get("port"), 5986 if use_https else 5985, 1, 65535),
        use_https=use_https,
        auth=_choice(raw.get("auth"), AUTHS, "ntlm"),
        username=str(raw.get("username") or "").strip(),
        password=password or "",
        verify_tls=_bool(raw.get("verify_tls"), True),
        server_search_base=str(raw.get("server_search_base") or "").strip(),
        backup_stale_days=_int(raw.get("backup_stale_days"), 7, 1, 365),
        mode=_choice(raw.get("mode"), MODES, "strict"),
        protected_objects=_strings(raw.get("protected_objects")),
        privileged_groups=_strings(raw.get("privileged_groups")),
        enable_powershell_escape=_bool(raw.get("enable_powershell_escape"), False),
    )


def _plugin_settings() -> Mapping[str, Any]:
    try:
        from hermes_cli.config import load_config_readonly
    except ImportError:
        return {}
    cfg = load_config_readonly() or {}
    entry = ((cfg.get("plugins") or {}).get("entries") or {}).get(PLUGIN_ID) or {}
    return entry.get("settings") or {}


def _password() -> str:
    try:
        from agent.secret_scope import UnscopedSecretError, get_secret
    except ImportError:
        return ""
    try:
        return get_secret(PASSWORD_ENV, None) or ""
    except UnscopedSecretError:
        return ""


def load_settings() -> Settings:
    try:
        return settings_from(_plugin_settings(), _password())
    except Exception:
        log.exception("hermes-sysadmin: could not load settings")
        return Settings()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/pytest tests/test_config.py`
Expected: `7 passed`

- [ ] **Step 5: Commit**

```bash
git add sysadmin/config.py tests/test_config.py
git commit -m "feat: plugin settings loader

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: PowerShell prelude and WinRM transport

**Files:**
- Create: `sysadmin/scripts/_prelude.ps1`, `sysadmin/transport.py`
- Test: `tests/test_transport.py`

**Interfaces:**
- Consumes: `Settings`, error classes.
- Produces: `Transport` protocol, `PsrpTransport(settings, prelude, *, pool_factory=None, ps_factory=None)`, `UnconfiguredTransport`. PowerShell globals available to every op script: `Invoke-Op`, `Get-HermesFanout`, `Iso`, `$Global:HermesCred`.

- [ ] **Step 1: Write the prelude** — `sysadmin/scripts/_prelude.ps1`

```powershell
# hermes-sysadmin session prelude.
# Runs ONCE per runspace pool, in global scope, right after the pool opens.
# Defines the helpers every op script uses. Never echoes $Pass.
param(
    [Parameter(Mandatory)][string]$User,
    [Parameter(Mandatory)][string]$Pass
)
$ErrorActionPreference = 'Stop'

# Explicit credential for second-hop work (Invoke-Command to member servers).
# NTLM cannot delegate the WinRM logon, so fan-out must pass credentials explicitly.
$Global:HermesCred = New-Object System.Management.Automation.PSCredential -ArgumentList $User, (ConvertTo-SecureString -String $Pass -AsPlainText -Force)
$Global:PSDefaultParameterValues['Invoke-Command:Credential'] = $Global:HermesCred
# AD cmdlets that talk to another DC (-Server / -Target) also need explicit credentials.
$Global:PSDefaultParameterValues['*-AD*:Credential'] = $Global:HermesCred

foreach ($m in 'ActiveDirectory', 'GroupPolicy') {
    if (Get-Module -ListAvailable -Name $m) { Import-Module $m -ErrorAction SilentlyContinue }
}

# GroupPolicy cmdlets have no -Credential. Pin them to THIS domain controller so AD and
# SYSVOL access stays local (loopback) and never needs a second hop.
$Global:HermesIsDc = ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4)
if ($Global:HermesIsDc) {
    $Global:HermesLocalDc = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
    $Global:PSDefaultParameterValues['*-GP*:Server'] = $Global:HermesLocalDc
}

function Global:Get-CnName {
    # 'CN=Bob Smith,OU=Staff,DC=corp' -> 'Bob Smith'
    param([string]$Dn)
    if (-not $Dn) { return $null }
    return ((($Dn -split '(?<!\\),')[0]) -replace '^(CN|OU|DC)=', '') -replace '\\,', ','
}

function Global:Get-ParentDn {
    param([string]$Dn)
    if (-not $Dn) { return $null }
    $parts = $Dn -split '(?<!\\),', 2
    if ($parts.Count -gt 1) { return $parts[1] }
    return $null
}

function Global:New-HermesPassword {
    # Cryptographically random password guaranteed to contain upper, lower, digit and symbol.
    param([int]$Length = 20)
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#%+=?@-')
    $all = -join $sets
    $bytes = New-Object byte[] $Length
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $chars = @(foreach ($b in $bytes) { $all[$b % $all.Length] })
    $shuffle = New-Object byte[] $sets.Count
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($shuffle)
    for ($i = 0; $i -lt $sets.Count; $i++) {
        $pos = $shuffle[$i] % $Length
        $chars[$pos] = $sets[$i][$bytes[$pos] % $sets[$i].Length]
    }
    return (-join $chars)
}

function Global:ConvertTo-HermesSecure {
    param([Parameter(Mandatory)][string]$Plain)
    return (ConvertTo-SecureString -String $Plain -AsPlainText -Force)
}

function Global:ConvertTo-LdapValue {
    # Escape a value for use inside an LDAP filter (RFC 4515).
    param([string]$Value)
    return ($Value -replace '\\', '\5c' -replace '\*', '\2a' -replace '\(', '\28' -replace '\)', '\29' -replace "`0", '\00')
}

function Global:Get-HermesGpo {
    # Resolve a GPO by GUID (with or without braces) or by display name.
    param([Parameter(Mandatory)][string]$Identity)
    if ($Identity -match '^\{?[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\}?$') { return Get-GPO -Guid $Identity.Trim('{}') }
    return Get-GPO -Name $Identity
}

function Global:Get-XmlText {
    # Text of an XML node whether PowerShell surfaced it as a string or an XmlNode (CDATA).
    param($Node)
    if ($null -eq $Node) { return '' }
    if ($Node -is [System.Xml.XmlNode]) { return $Node.InnerText }
    return "$Node"
}

function Global:Assert-Hermes {
    # Script-side validation that maps to InvalidArguments.
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { Write-Error -Message $Message -Category InvalidArgument -ErrorAction Stop }
}

function Global:Iso {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    try { return ([datetime]$Value).ToUniversalTime().ToString('o') } catch { return "$Value" }
}

function Global:Get-HermesErrorType {
    param($Err)
    $name = $Err.Exception.GetType().Name
    $cat = "$($Err.CategoryInfo.Category)"
    $msg = "$($Err.Exception.Message)"
    if ($name -match 'IdentityNotFound|NotFound' -or $cat -eq 'ObjectNotFound' -or $msg -match 'Cannot find an object|was not found|does not exist') { return 'NotFound' }
    if ($name -match 'UnauthorizedAccess' -or $cat -in @('PermissionDenied', 'SecurityError') -or $msg -match 'Access is denied|Insufficient access rights') { return 'PermissionDenied' }
    if ($cat -in @('InvalidArgument', 'InvalidData')) { return 'InvalidArguments' }
    if ($msg -match 'timed out|timeout') { return 'Timeout' }
    return 'RemoteScriptError'
}

function Global:Invoke-Op {
    param([Parameter(Mandatory)][scriptblock]$Body)
    $ErrorActionPreference = 'Stop'
    try {
        $data = & $Body
        return (ConvertTo-Json -InputObject @{ ok = $true; data = $data } -Depth 10 -Compress)
    } catch {
        $e = $_
        $err = @{
            type     = (Get-HermesErrorType $e)
            message  = "$($e.Exception.Message)"
            category = "$($e.CategoryInfo.Category)"
            target   = "$($e.TargetObject)"
        }
        return (ConvertTo-Json -InputObject @{ ok = $false; error = $err } -Depth 5 -Compress)
    }
}

function Global:Get-HermesFanout {
    # Runs $Script on each computer with the explicit credential.
    # The remote scriptblock MUST emit [pscustomobject]@{...} values.
    param(
        [Parameter(Mandatory)][string[]]$Computers,
        [Parameter(Mandatory)][scriptblock]$Script,
        [object[]]$ArgumentList = @()
    )
    $errs = $null
    $raw = Invoke-Command -ComputerName $Computers -ScriptBlock $Script -ArgumentList $ArgumentList -ThrottleLimit 16 -ErrorAction SilentlyContinue -ErrorVariable errs
    $results = @(foreach ($r in $raw) {
        $h = @{}
        foreach ($p in $r.PSObject.Properties) {
            if ($p.Name -notin @('PSComputerName', 'RunspaceId', 'PSShowComputerName')) { $h[$p.Name] = $p.Value }
        }
        $h['host'] = "$($r.PSComputerName)"
        $h
    })
    $failed = @(foreach ($e in @($errs)) {
        $hostName = if ($e.OriginInfo -and $e.OriginInfo.PSComputerName) { "$($e.OriginInfo.PSComputerName)" } else { "$($e.TargetObject)" }
        @{ host = $hostName; message = "$($e.Exception.Message)" }
    })
    return @{ results = $results; errors = $failed }
}
```

- [ ] **Step 2: Write the failing test** — `tests/test_transport.py`

```python
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
```

- [ ] **Step 3: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_transport.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'sysadmin.transport'`

- [ ] **Step 4: Implement** — `sysadmin/transport.py`

```python
"""WinRM/PSRP transport: one pooled runspace to the jump host, serialized by a lock."""

from __future__ import annotations

import logging
import threading
from contextlib import suppress
from typing import Any, Callable, Mapping, Protocol

from .config import Settings
from .errors import ConnectionFailed, NotConfigured, RemoteScriptError, Timeout

log = logging.getLogger(__name__)


class Transport(Protocol):
    def invoke(self, script: str, params: Mapping[str, Any]) -> list[Any]: ...

    def close(self) -> None: ...


class UnconfiguredTransport:
    def invoke(self, script: str, params: Mapping[str, Any]) -> list[Any]:
        raise NotConfigured("hermes-sysadmin has no WinRM connection configured.")

    def close(self) -> None:
        return None


def _default_pool_factory(settings: Settings) -> Any:
    from pypsrp.powershell import RunspacePool
    from pypsrp.wsman import WSMan

    wsman = WSMan(
        settings.host,
        port=settings.port,
        ssl=settings.use_https,
        auth=settings.auth,
        username=settings.username,
        password=settings.password,
        cert_validation=settings.verify_tls,
        encryption="auto",
        connection_timeout=15,
        operation_timeout=60,
        read_timeout=90,
    )
    return RunspacePool(wsman)


def _default_ps_factory(pool: Any) -> Any:
    from pypsrp.powershell import PowerShell

    return PowerShell(pool)


def _map_exception(exc: BaseException, host: str) -> Exception:
    import requests

    try:
        from pypsrp.exceptions import AuthenticationError, WinRMTransportError
    except ImportError:  # pragma: no cover
        AuthenticationError = WinRMTransportError = ()  # type: ignore[assignment]

    text = str(exc)
    if isinstance(exc, AuthenticationError) or (
        isinstance(exc, WinRMTransportError) and getattr(exc, "code", None) == 401
    ):
        return ConnectionFailed(
            f"Authentication to {host} failed.",
            hint="Check the username (DOMAIN\\user or user@domain), the password and the auth type.",
        )
    if isinstance(exc, (requests.exceptions.ReadTimeout, requests.exceptions.ConnectTimeout)):
        return Timeout(f"{host} did not respond in time.")
    if isinstance(exc, requests.exceptions.SSLError):
        return ConnectionFailed(
            f"TLS handshake with {host} failed: {text}",
            hint="Trust the WinRM certificate's CA on this machine, or turn off 'Verify TLS' for a lab.",
        )
    if isinstance(exc, requests.exceptions.ConnectionError):
        return ConnectionFailed(f"Cannot reach {host}: {text}")
    return ConnectionFailed(f"WinRM error talking to {host}: {type(exc).__name__}: {text}")


class PsrpTransport:
    def __init__(
        self,
        settings: Settings,
        prelude: str,
        *,
        pool_factory: Callable[[Settings], Any] | None = None,
        ps_factory: Callable[[Any], Any] | None = None,
    ) -> None:
        self._settings = settings
        self._prelude = prelude
        self._pool_factory = pool_factory or _default_pool_factory
        self._ps_factory = ps_factory or _default_ps_factory
        self._lock = threading.RLock()
        self._pool: Any = None

    def _open(self) -> Any:
        pool = self._pool_factory(self._settings)
        if hasattr(pool, "open"):
            pool.open()
        ps = self._ps_factory(pool)
        ps.add_script(self._prelude, use_local_scope=False)
        ps.add_parameter("User", self._settings.username)
        ps.add_parameter("Pass", self._settings.password)
        ps.invoke()
        if ps.had_errors:
            message = str(ps.streams.error[0]) if ps.streams.error else "prelude failed"
            with suppress(Exception):
                pool.close()
            raise RemoteScriptError(f"Session setup failed on {self._settings.host}: {message}")
        return pool

    def _drop(self) -> None:
        pool, self._pool = self._pool, None
        if pool is not None:
            with suppress(Exception):
                pool.close()

    def invoke(self, script: str, params: Mapping[str, Any]) -> list[Any]:
        with self._lock:
            try:
                if self._pool is None:
                    self._pool = self._open()
                ps = self._ps_factory(self._pool)
                ps.add_script(script)
                for name, value in params.items():
                    ps.add_parameter(name, value)
                out = ps.invoke()
            except RemoteScriptError:
                self._drop()
                raise
            except Exception as exc:
                self._drop()
                raise _map_exception(exc, self._settings.host) from exc
            if ps.had_errors and not out:
                message = "; ".join(str(e) for e in list(ps.streams.error)[:3]) or "unknown error"
                raise RemoteScriptError(message)
            return list(out or [])

    def close(self) -> None:
        with self._lock:
            self._drop()
```

- [ ] **Step 5: Run test to verify it passes**

Run: `.venv/bin/pytest tests/test_transport.py`
Expected: `6 passed`

- [ ] **Step 6: Commit**

```bash
git add sysadmin/scripts/_prelude.ps1 sysadmin/transport.py tests/test_transport.py
git commit -m "feat: WinRM transport with session prelude

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Runner and output contract

**Files:**
- Create: `sysadmin/runner.py`
- Test: `tests/test_runner.py`

**Interfaces:**
- Consumes: `Transport`, `ConnectionFailed`, `ERROR_TYPES`, `InvalidArguments`, `RemoteScriptError`.
- Produces: `SCRIPTS_DIR`, `load_prelude()`, `parse_output(out)`, `Runner(transport, scripts_dir)` with `.run(script, params, *, retry=False)`, `.run_text(text, params)`, `.close()`.

- [ ] **Step 1: Write the failing test** — `tests/test_runner.py`

```python
import pytest

from sysadmin.errors import ConnectionFailed, InvalidArguments, NotFound, PermissionDenied, RemoteScriptError
from sysadmin.runner import Runner, load_prelude, parse_output


class FakeTransport:
    def __init__(self, outputs):
        self.outputs = list(outputs)
        self.calls = []

    def invoke(self, script, params):
        self.calls.append((script, dict(params)))
        out = self.outputs.pop(0)
        if isinstance(out, BaseException):
            raise out
        return out

    def close(self):
        pass


@pytest.fixture
def scripts(tmp_path):
    (tmp_path / "hello.ps1").write_text("param($Name) Invoke-Op { @{ hi = $Name } }", encoding="utf-8")
    (tmp_path / "_prelude.ps1").write_text("PRELUDE", encoding="utf-8")
    return tmp_path


def test_parse_output_returns_data_from_last_json_line():
    assert parse_output(["noise", '{"ok":true,"data":{"a":1}}']) == {"a": 1}


def test_parse_output_maps_error_types():
    with pytest.raises(NotFound) as info:
        parse_output(['{"ok":false,"error":{"type":"NotFound","message":"no bob","target":"bob"}}'])
    assert info.value.details["target"] == "bob"
    with pytest.raises(PermissionDenied):
        parse_output(['{"ok":false,"error":{"type":"PermissionDenied","message":"denied"}}'])


def test_parse_output_unknown_error_type_is_remote_script_error():
    with pytest.raises(RemoteScriptError):
        parse_output(['{"ok":false,"error":{"type":"Weird","message":"x"}}'])


@pytest.mark.parametrize("out", [[], ["not json"], ["{bad"], ['{"data":1}']])
def test_parse_output_rejects_bad_output(out):
    with pytest.raises(RemoteScriptError):
        parse_output(out)


def test_run_loads_script_drops_none_params_and_parses(scripts):
    t = FakeTransport([['{"ok":true,"data":{"hi":"bob"}}']])
    r = Runner(t, scripts_dir=scripts)
    assert r.run("hello", {"Name": "bob", "Skip": None}) == {"hi": "bob"}
    assert t.calls == [("param($Name) Invoke-Op { @{ hi = $Name } }", {"Name": "bob"})]


def test_run_retries_once_on_connection_failure_when_requested(scripts):
    t = FakeTransport([ConnectionFailed("down"), ['{"ok":true,"data":1}']])
    assert Runner(t, scripts_dir=scripts).run("hello", {}, retry=True) == 1
    assert len(t.calls) == 2


def test_run_without_retry_raises_first_failure(scripts):
    t = FakeTransport([ConnectionFailed("down"), ['{"ok":true,"data":1}']])
    with pytest.raises(ConnectionFailed):
        Runner(t, scripts_dir=scripts).run("hello", {})
    assert len(t.calls) == 1


@pytest.mark.parametrize("name", ["../etc", "Hello", "missing", "a-b"])
def test_run_rejects_bad_or_missing_script_names(scripts, name):
    with pytest.raises(InvalidArguments):
        Runner(FakeTransport([]), scripts_dir=scripts).run(name, {})


def test_run_text_sends_text_verbatim(scripts):
    t = FakeTransport([['{"ok":true,"data":"x"}']])
    assert Runner(t, scripts_dir=scripts).run_text("Invoke-Op { 'x' }", {}) == "x"
    assert t.calls[0][0] == "Invoke-Op { 'x' }"


def test_load_prelude_reads_prelude(scripts):
    assert load_prelude(scripts) == "PRELUDE"


def test_real_prelude_defines_helpers():
    text = load_prelude()
    for name in (
        "function Global:Invoke-Op", "function Global:Get-HermesFanout", "function Global:Iso",
        "function Global:Get-CnName", "function Global:Get-ParentDn", "function Global:New-HermesPassword",
        "function Global:ConvertTo-HermesSecure", "function Global:Assert-Hermes",
        "function Global:ConvertTo-LdapValue", "function Global:Get-HermesGpo", "function Global:Get-XmlText",
        "$Global:HermesCred", "'*-AD*:Credential'", "'*-GP*:Server'",
    ):
        assert name in text
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_runner.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'sysadmin.runner'`

- [ ] **Step 3: Implement** — `sysadmin/runner.py`

```python
"""Runs vetted op scripts through a Transport and enforces the {ok, data|error} output contract."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Mapping

from .errors import ERROR_TYPES, ConnectionFailed, InvalidArguments, RemoteScriptError
from .transport import Transport

SCRIPTS_DIR = Path(__file__).resolve().parent / "scripts"
_SCRIPT_NAME = re.compile(r"^[a-z][a-z0-9_]*$")


def load_prelude(scripts_dir: Path = SCRIPTS_DIR) -> str:
    return (scripts_dir / "_prelude.ps1").read_text(encoding="utf-8")


def parse_output(out: list[Any]) -> Any:
    candidates = [o for o in out if isinstance(o, str) and o.strip().startswith("{")]
    if not candidates:
        raise RemoteScriptError(
            "The script returned no result.", output=" | ".join(str(o) for o in out)[:300]
        )
    text = candidates[-1]
    try:
        payload = json.loads(text)
    except ValueError as exc:
        raise RemoteScriptError("The script returned malformed JSON.", output=text[:300]) from exc
    if not isinstance(payload, dict) or "ok" not in payload:
        raise RemoteScriptError("The script result is missing 'ok'.", output=text[:300])
    if payload["ok"]:
        return payload.get("data")
    err = payload.get("error") or {}
    cls = ERROR_TYPES.get(str(err.get("type")), RemoteScriptError)
    raise cls(
        str(err.get("message") or "The remote script failed."),
        category=err.get("category"),
        target=err.get("target"),
    )


class Runner:
    def __init__(self, transport: Transport, scripts_dir: Path = SCRIPTS_DIR) -> None:
        self._transport = transport
        self._dir = scripts_dir
        self._cache: dict[str, str] = {}

    def close(self) -> None:
        self._transport.close()

    def load_script(self, name: str) -> str:
        if not _SCRIPT_NAME.match(name):
            raise InvalidArguments(f"Invalid script name {name!r}.")
        if name not in self._cache:
            path = self._dir / f"{name}.ps1"
            if not path.is_file():
                raise InvalidArguments(f"No script named {name!r}.")
            self._cache[name] = path.read_text(encoding="utf-8")
        return self._cache[name]

    def run(self, script: str, params: Mapping[str, Any], *, retry: bool = False) -> Any:
        return self._invoke(self.load_script(script), params, retry=retry)

    def run_text(self, text: str, params: Mapping[str, Any]) -> Any:
        return self._invoke(text, params, retry=False)

    def _invoke(self, text: str, params: Mapping[str, Any], *, retry: bool) -> Any:
        clean = {k: v for k, v in params.items() if v is not None}
        attempts = 2 if retry else 1
        out: list[Any] = []
        for attempt in range(attempts):
            try:
                out = self._transport.invoke(text, clean)
                break
            except ConnectionFailed:
                if attempt + 1 >= attempts:
                    raise
        return parse_output(out)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/pytest tests/test_runner.py`
Expected: `17 passed`

- [ ] **Step 5: Commit**

```bash
git add sysadmin/runner.py tests/test_runner.py
git commit -m "feat: script runner and output contract

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Operation registry

**Files:**
- Create: `sysadmin/registry.py`
- Test: `tests/test_registry.py`

**Interfaces:**
- Consumes: `InvalidArguments`.
- Produces: `Param`, `Op`, `OPS`, `TIERS`, `register()`, `schema_for()`, `coerce_args()`, `ps_params()`, `target_of()`.

- [ ] **Step 1: Write the failing test** — `tests/test_registry.py`

```python
import pytest

from sysadmin.errors import InvalidArguments
from sysadmin.registry import OPS, Op, Param, coerce_args, ps_params, register, schema_for, target_of

OP = Op(
    name="t_reg_unlock",
    toolset="t",
    tier="W",
    script="t_reg_unlock",
    description="Unlock a user.",
    params=(
        Param("identity", "string", "sAMAccountName", required=True),
        Param("days", "integer", "Days", minimum=1, default=30),
        Param("force", "boolean", "Force"),
        Param("hosts", "array", "Hosts"),
        Param("kind", "string", "Kind", enum=("user", "group")),
        Param("ou_dn", "string", "OU", ps="SearchBase"),
    ),
)


def test_param_ps_name_is_camel_case_unless_overridden():
    assert Param("new_password", "string", "x").ps_name == "NewPassword"
    assert Param("ou_dn", "string", "x", ps="SearchBase").ps_name == "SearchBase"


def test_schema_for_is_openai_style_with_tier_label():
    schema = schema_for(OP)
    assert schema["name"] == "t_reg_unlock"
    assert schema["description"].startswith("[write · needs approval] ")
    params = schema["parameters"]
    assert params["required"] == ["identity"]
    assert params["additionalProperties"] is False
    assert params["properties"]["days"] == {"type": "integer", "description": "Days", "default": 30, "minimum": 1}
    assert params["properties"]["hosts"]["items"] == {"type": "string"}
    assert params["properties"]["kind"]["enum"] == ["user", "group"]


def test_coerce_args_applies_defaults_and_coerces_types():
    out = coerce_args(OP, {"identity": " bob ", "force": "true", "hosts": "a, b", "days": "5"})
    assert out == {"identity": "bob", "days": 5, "force": True, "hosts": ["a", "b"]}


@pytest.mark.parametrize(
    "args, message",
    [
        ({}, "'identity' is required"),
        ({"identity": "   "}, "'identity' is required"),
        ({"identity": "b", "nope": 1}, "Unknown argument"),
        ({"identity": "b", "days": 0}, "must be ≥ 1"),
        ({"identity": "b", "days": True}, "must be an integer"),
        ({"identity": "b", "force": "maybe"}, "true or false"),
        ({"identity": "b", "kind": "ou"}, "must be one of"),
        ({"identity": "b", "hosts": [1]}, "list of strings"),
        ({"identity": ["b"]}, "must be a string"),
    ],
)
def test_coerce_args_rejects_bad_input(args, message):
    with pytest.raises(InvalidArguments, match=message):
        coerce_args(OP, args)


def test_ps_params_maps_names():
    assert ps_params(OP, {"identity": "bob", "ou_dn": "OU=X", "days": 3}) == {
        "Identity": "bob", "SearchBase": "OU=X", "Days": 3,
    }


def test_target_of_uses_target_fn_or_first_required_param():
    assert target_of(OP, {"identity": "bob"}) == "bob"
    op = Op("t_x", "t", "R", "t_x", "d", target=lambda a: f"{a['g']} ← {a['m']}")
    assert target_of(op, {"g": "Admins", "m": "bob"}) == "Admins ← bob"


def test_register_rejects_duplicates_bad_tier_and_read_preview(scratch_ops):
    scratch_ops(Op("t_reg_once", "t", "R", "t_reg_once", "d"))
    with pytest.raises(ValueError):
        register(Op("t_reg_once", "t", "R", "t_reg_once", "d"))
    with pytest.raises(ValueError):
        register(Op("t_reg_bad", "t", "X", "t_reg_bad", "d"))
    with pytest.raises(ValueError):
        register(Op("t_reg_prev", "t", "R", "t_reg_prev", "d", preview=True))
    assert "t_reg_once" in OPS
```

Add the `scratch_ops` fixture to `tests/conftest.py` (replace the file):

```python
"""Shared test fixtures for hermes-sysadmin."""

import pytest

from sysadmin.registry import OPS, register


@pytest.fixture
def scratch_ops():
    """Register temporary ops (names must start with 't_') and remove them afterwards."""
    added = []

    def add(op):
        assert op.name.startswith("t_")
        register(op)
        added.append(op.name)
        return op

    yield add
    for name in added:
        OPS.pop(name, None)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_registry.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'sysadmin.registry'`

- [ ] **Step 3: Implement** — `sysadmin/registry.py`

```python
"""Declarative operation registry. One Op == one agent tool == one PowerShell script."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable, Mapping

from .errors import InvalidArguments

TIERS = ("R", "W", "H")
TIER_LABEL = {"R": "read-only", "W": "write · needs approval", "H": "high-risk · needs approval"}


@dataclass(frozen=True)
class Param:
    name: str
    type: str  # "string" | "integer" | "boolean" | "array"
    description: str
    required: bool = False
    ps: str | None = None
    enum: tuple[str, ...] | None = None
    default: Any = None
    items: str = "string"
    minimum: int | None = None

    @property
    def ps_name(self) -> str:
        return self.ps or "".join(part.capitalize() for part in self.name.split("_"))


@dataclass(frozen=True)
class Op:
    name: str
    toolset: str
    tier: str
    script: str
    description: str
    params: tuple[Param, ...] = ()
    target: Callable[[Mapping[str, Any]], str] | None = None
    identities: tuple[str, ...] = ()
    escalate: Callable[[Mapping[str, Any], Any, Any], bool] | None = None
    preview: bool = False
    post: Callable[[Any, Mapping[str, Any], Any], Any] | None = None
    cache_ttl: float = 0.0
    inject: Callable[[Any], Mapping[str, Any]] | None = None  # extra PS params derived from Settings


OPS: dict[str, Op] = {}


def register(op: Op) -> Op:
    if op.tier not in TIERS:
        raise ValueError(f"{op.name}: tier must be one of {TIERS}")
    if op.name in OPS:
        raise ValueError(f"duplicate op {op.name}")
    if op.preview and op.tier == "R":
        raise ValueError(f"{op.name}: read ops cannot preview")
    names = [p.name for p in op.params]
    if len(set(names)) != len(names):
        raise ValueError(f"{op.name}: duplicate parameter names")
    OPS[op.name] = op
    return op


def schema_for(op: Op) -> dict[str, Any]:
    props: dict[str, Any] = {}
    for p in op.params:
        spec: dict[str, Any] = {"type": p.type, "description": p.description}
        if p.enum:
            spec["enum"] = list(p.enum)
        if p.type == "array":
            spec["items"] = {"type": p.items}
        if p.default is not None:
            spec["default"] = p.default
        if p.minimum is not None:
            spec["minimum"] = p.minimum
        props[p.name] = spec
    return {
        "name": op.name,
        "description": f"[{TIER_LABEL[op.tier]}] {op.description}",
        "parameters": {
            "type": "object",
            "properties": props,
            "required": [p.name for p in op.params if p.required],
            "additionalProperties": False,
        },
    }


def _coerce(p: Param, value: Any) -> Any:
    if p.type == "string":
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            value = str(value)
        if not isinstance(value, str):
            raise InvalidArguments(f"'{p.name}' must be a string.")
        value = value.strip()
        if p.enum and value not in p.enum:
            raise InvalidArguments(f"'{p.name}' must be one of: {', '.join(p.enum)}.")
        return value
    if p.type == "integer":
        if isinstance(value, bool):
            raise InvalidArguments(f"'{p.name}' must be an integer.")
        if isinstance(value, str) and value.strip().lstrip("-").isdigit():
            value = int(value.strip())
        if not isinstance(value, int):
            raise InvalidArguments(f"'{p.name}' must be an integer.")
        if p.minimum is not None and value < p.minimum:
            raise InvalidArguments(f"'{p.name}' must be ≥ {p.minimum}.")
        return value
    if p.type == "boolean":
        if isinstance(value, str) and value.strip().lower() in ("true", "false"):
            value = value.strip().lower() == "true"
        if not isinstance(value, bool):
            raise InvalidArguments(f"'{p.name}' must be true or false.")
        return value
    if p.type == "array":
        if isinstance(value, str):
            value = [s for s in value.split(",")]
        if not isinstance(value, list) or not all(isinstance(x, str) for x in value):
            raise InvalidArguments(f"'{p.name}' must be a list of strings.")
        return [x.strip() for x in value if x.strip()]
    raise InvalidArguments(f"Unsupported parameter type for '{p.name}'.")


def coerce_args(op: Op, args: Mapping[str, Any] | None) -> dict[str, Any]:
    args = dict(args or {})
    known = {p.name for p in op.params}
    unknown = sorted(set(args) - known)
    if unknown:
        raise InvalidArguments(f"Unknown argument(s) for {op.name}: {', '.join(unknown)}.")
    out: dict[str, Any] = {}
    for p in op.params:
        value = args.get(p.name)
        if value is not None and value != "" and value != []:
            value = _coerce(p, value)
        if value is None or value == "" or value == []:
            if p.required:
                raise InvalidArguments(f"'{p.name}' is required.")
            if p.default is not None:
                out[p.name] = p.default
            continue
        out[p.name] = value
    return out


def ps_params(op: Op, args: Mapping[str, Any]) -> dict[str, Any]:
    by_name = {p.name: p for p in op.params}
    return {by_name[k].ps_name: v for k, v in args.items() if k in by_name}


def target_of(op: Op, args: Mapping[str, Any]) -> str:
    if op.target is not None:
        return str(op.target(args))
    for p in op.params:
        if p.required and p.name in args:
            value = args[p.name]
            return ", ".join(value) if isinstance(value, list) else str(value)
    return ""
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/pytest tests/test_registry.py`
Expected: `15 passed`

- [ ] **Step 5: Commit**

```bash
git add sysadmin/registry.py tests/test_registry.py tests/conftest.py
git commit -m "feat: declarative operation registry

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Safety policy

**Files:**
- Create: `sysadmin/policy.py`
- Test: `tests/test_policy.py`

**Interfaces:**
- Consumes: `Op`, `Settings`.
- Produces: `Decision(action, tier, reason, needs_preview)`, `Facts` protocol, `NoFacts`, `decide(op, args, settings, facts=None)`, `is_privileged_group(name, settings)`, `is_domain_controller_name(host, dcs)`, `normalize_identity(value)`, `PROTECTED_DEFAULT`, `PRIVILEGED_DEFAULT`.

- [ ] **Step 1: Write the failing test** — `tests/test_policy.py`

```python
import pytest

from sysadmin.config import Settings
from sysadmin.policy import (
    decide,
    is_domain_controller_name,
    is_privileged_group,
    normalize_identity,
)
from sysadmin.registry import Op, Param

READ = Op("t_p_read", "t", "R", "t", "d", params=(Param("identity", "string", "x"),))
WRITE = Op("t_p_write", "t", "W", "t", "d", params=(Param("identity", "string", "x"),), identities=("identity",))
HIGH = Op("t_p_high", "t", "H", "t", "d", params=(Param("identity", "string", "x"),), identities=("identity",), preview=True)
GROUP = Op(
    "t_p_group", "t", "W", "t", "d",
    params=(Param("group", "string", "g"), Param("members", "array", "m")),
    identities=("members",),
    escalate=lambda args, settings, facts: is_privileged_group(args["group"], settings),
)

STRICT = Settings(mode="strict")
PERMISSIVE = Settings(mode="permissive")
READONLY = Settings(mode="read-only")


@pytest.mark.parametrize(
    "op, settings, action, tier",
    [
        (READ, STRICT, "allow", "R"),
        (READ, READONLY, "allow", "R"),
        (WRITE, STRICT, "approve", "W"),
        (WRITE, PERMISSIVE, "allow", "W"),
        (WRITE, READONLY, "block", "W"),
        (HIGH, STRICT, "approve", "H"),
        (HIGH, PERMISSIVE, "approve", "H"),
        (HIGH, READONLY, "block", "H"),
    ],
)
def test_mode_tier_matrix(op, settings, action, tier):
    d = decide(op, {"identity": "bob"}, settings)
    assert (d.action, d.tier) == (action, tier)


def test_high_risk_requests_preview_only_when_op_supports_it():
    assert decide(HIGH, {"identity": "bob"}, STRICT).needs_preview is True
    assert decide(WRITE, {"identity": "bob"}, STRICT).needs_preview is False


@pytest.mark.parametrize("ident", ["krbtgt", "KRBTGT", "CORP\\Administrator", "administrator@corp.local", "CN=krbtgt,CN=Users,DC=corp"])
def test_builtin_protected_objects_are_blocked_in_every_mode(ident):
    for settings in (STRICT, PERMISSIVE):
        d = decide(WRITE, {"identity": ident}, settings)
        assert (d.action, d.tier) == ("block", "P")
        assert "protected" in d.reason


def test_configured_protected_objects_and_list_identities():
    s = Settings(protected_objects=("svc-sql",))
    assert decide(GROUP, {"group": "Staff", "members": ["amy", "SVC-SQL"]}, s).tier == "P"


def test_privileged_group_escalates_to_high():
    assert decide(GROUP, {"group": "Domain Admins", "members": ["bob"]}, STRICT).tier == "H"
    assert decide(GROUP, {"group": "CN=Enterprise Admins,CN=Users,DC=corp", "members": ["bob"]}, PERMISSIVE).action == "approve"
    assert decide(GROUP, {"group": "Finance-RW", "members": ["bob"]}, PERMISSIVE).action == "allow"
    assert decide(GROUP, {"group": "Tier0", "members": ["bob"]}, Settings(privileged_groups=("Tier0",))).tier == "H"


def test_normalize_identity_strips_dn_domain_and_upn():
    assert normalize_identity("CN=Bob Smith,OU=Staff,DC=corp") == "bob smith"
    assert normalize_identity("CORP\\bob") == "bob"
    assert normalize_identity("bob@corp.local") == "bob"


def test_is_domain_controller_name_matches_short_or_fqdn():
    assert is_domain_controller_name("dc01.corp.local", ["DC01"])
    assert is_domain_controller_name("DC02", ["dc02.corp.local"])
    assert not is_domain_controller_name("srv-app02", ["DC01"])
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_policy.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'sysadmin.policy'`

- [ ] **Step 3: Implement** — `sysadmin/policy.py`

```python
"""Tiered safety policy shared by the approval hook, the service and the dashboard."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterable, Mapping, Protocol

PROTECTED_DEFAULT = ("krbtgt", "administrator")
PRIVILEGED_DEFAULT = (
    "domain admins",
    "enterprise admins",
    "schema admins",
    "administrators",
    "account operators",
    "server operators",
    "backup operators",
    "print operators",
    "group policy creator owners",
    "dnsadmins",
    "key admins",
    "enterprise key admins",
)


@dataclass(frozen=True)
class Decision:
    action: str  # "allow" | "approve" | "block"
    tier: str  # "R" | "W" | "H" | "P"
    reason: str
    needs_preview: bool = False


class Facts(Protocol):
    def domain_controllers(self) -> list[str] | None: ...


class NoFacts:
    def domain_controllers(self) -> list[str] | None:
        return None


def normalize_identity(value: str) -> str:
    text = value.strip()
    if text.lower().startswith("cn="):
        text = text[3:].split(",", 1)[0]
    if "\\" in text:
        text = text.split("\\", 1)[1]
    if "@" in text:
        text = text.split("@", 1)[0]
    return text.strip().lower()


def is_privileged_group(name: str, settings: Any) -> bool:
    pool = set(PRIVILEGED_DEFAULT) | {normalize_identity(g) for g in settings.privileged_groups}
    return normalize_identity(name) in pool


def is_domain_controller_name(host: str, dcs: Iterable[str]) -> bool:
    short = host.strip().lower().split(".", 1)[0]
    return any(short == d.strip().lower().split(".", 1)[0] for d in dcs)


def _protected_hit(op: Any, args: Mapping[str, Any], settings: Any) -> str | None:
    pool = set(PROTECTED_DEFAULT) | {normalize_identity(p) for p in settings.protected_objects}
    for key in op.identities:
        value = args.get(key)
        for item in value if isinstance(value, list) else [value]:
            if isinstance(item, str) and item and normalize_identity(item) in pool:
                return item
    return None


def decide(op: Any, args: Mapping[str, Any], settings: Any, facts: Facts | None = None) -> Decision:
    if op.tier == "R":
        return Decision("allow", "R", "Read-only operation.")
    hit = _protected_hit(op, args, settings)
    if hit:
        return Decision(
            "block", "P",
            f"'{hit}' is a protected object; changes to it are blocked by the hermes-sysadmin policy.",
        )
    escalated = bool(op.escalate and op.escalate(args, settings, facts or NoFacts()))
    tier = "H" if op.tier == "H" or escalated else "W"
    if settings.mode == "read-only":
        return Decision("block", tier, "hermes-sysadmin is in read-only mode; writes are disabled in its settings.")
    if tier == "H":
        return Decision("approve", "H", "High-risk change: requires approval with a preview.", needs_preview=op.preview)
    if settings.mode == "permissive":
        return Decision("allow", "W", "Permissive mode: standard writes run without approval.")
    return Decision("approve", "W", "Write operation: requires approval.")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/pytest tests/test_policy.py`
Expected: `18 passed`

- [ ] **Step 5: Commit**

```bash
git add sysadmin/policy.py tests/test_policy.py
git commit -m "feat: tiered safety policy

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Audit log

**Files:**
- Create: `sysadmin/audit.py`
- Test: `tests/test_audit.py`

**Interfaces:**
- Consumes: `PLUGIN_ID`.
- Produces: `SECRET_KEYS`, `redact(args)`, `AuditLog(conn)` with `.record(...)`/`.query(...)`, `open_audit()`.

- [ ] **Step 1: Write the failing test** — `tests/test_audit.py`

```python
import sqlite3

from sysadmin.audit import AuditLog, open_audit, redact


def make():
    return AuditLog(sqlite3.connect(":memory:", check_same_thread=False))


def test_redact_hides_password_keys_only():
    assert redact({"identity": "bob", "password": "x", "New_Password": "y"}) == {
        "identity": "bob", "password": "[redacted]", "New_Password": "[redacted]",
    }


def test_record_and_query_newest_first_with_redaction():
    log = make()
    log.record(actor="agent", session="s1", tool="ad_user_unlock", target="bob", tier="W", decision="approved", result="ok", params={"identity": "bob"})
    log.record(actor="dashboard", session="", tool="ad_user_reset_password", target="amy", tier="W", decision="confirmed", result="ok", params={"identity": "amy", "password": "secret"})
    rows = log.query()
    assert [r["tool"] for r in rows] == ["ad_user_reset_password", "ad_user_unlock"]
    assert rows[0]["params"] == {"identity": "amy", "password": "[redacted]"}
    assert rows[0]["ts"].endswith("+00:00")
    assert "secret" not in str(rows)


def test_query_filters_by_actor_and_decision_prefix_and_limit():
    log = make()
    for i in range(5):
        log.record(actor="agent", session="", tool=f"t{i}", target="", tier="W", decision="approved", result="ok", params={})
    log.record(actor="agent", session="", tool="x", target="krbtgt", tier="P", decision="blocked: protected", result="-", params={})
    log.record(actor="dashboard", session="", tool="y", target="", tier="W", decision="confirmed", result="ok", params={})
    assert [r["tool"] for r in log.query(decision="blocked")] == ["x"]
    assert [r["tool"] for r in log.query(actor="dashboard")] == ["y"]
    assert len(log.query(limit=2)) == 2


def test_long_results_are_truncated():
    log = make()
    log.record(actor="agent", session="", tool="t", target="", tier="W", decision="approved", result="e" * 2000, params={})
    assert len(log.query()[0]["result"]) == 500


def test_open_audit_without_hermes_uses_memory_db():
    log = open_audit()
    log.record(actor="agent", session="", tool="t", target="", tier="W", decision="approved", result="ok", params={})
    assert log.query()[0]["tool"] == "t"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_audit.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'sysadmin.audit'`

- [ ] **Step 3: Implement** — `sysadmin/audit.py`

```python
"""Local SQLite audit log of every write attempt (allowed, approved, denied, blocked or failed)."""

from __future__ import annotations

import json
import sqlite3
import threading
from datetime import datetime, timezone
from typing import Any, Mapping

from . import PLUGIN_ID

SECRET_KEYS = frozenset({"password", "new_password"})
_COLUMNS = ("id", "ts", "actor", "session", "tool", "target", "tier", "decision", "result", "params")
_SCHEMA = """
CREATE TABLE IF NOT EXISTS audit (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    actor TEXT NOT NULL,
    session TEXT NOT NULL DEFAULT '',
    tool TEXT NOT NULL,
    target TEXT NOT NULL DEFAULT '',
    tier TEXT NOT NULL,
    decision TEXT NOT NULL,
    result TEXT NOT NULL,
    params TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS audit_ts ON audit(ts);
"""


def redact(args: Mapping[str, Any] | None) -> dict[str, Any]:
    return {k: ("[redacted]" if k.lower() in SECRET_KEYS else v) for k, v in (args or {}).items()}


class AuditLog:
    def __init__(self, conn: sqlite3.Connection) -> None:
        self._conn = conn
        self._lock = threading.Lock()
        with self._lock:
            conn.executescript(_SCHEMA)
            conn.commit()

    def record(
        self, *, actor: str, session: str, tool: str, target: str, tier: str,
        decision: str, result: str, params: Mapping[str, Any],
    ) -> None:
        row = (
            datetime.now(timezone.utc).isoformat(timespec="seconds"),
            actor,
            session or "",
            tool,
            target or "",
            tier,
            decision,
            str(result)[:500],
            json.dumps(redact(params), default=str)[:4000],
        )
        with self._lock:
            self._conn.execute(
                "INSERT INTO audit (ts, actor, session, tool, target, tier, decision, result, params) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                row,
            )
            self._conn.commit()

    def query(self, *, limit: int = 100, actor: str | None = None, decision: str | None = None) -> list[dict[str, Any]]:
        sql = f"SELECT {', '.join(_COLUMNS)} FROM audit"
        where: list[str] = []
        values: list[Any] = []
        if actor:
            where.append("actor = ?")
            values.append(actor)
        if decision:
            where.append("decision LIKE ?")
            values.append(f"{decision}%")
        if where:
            sql += " WHERE " + " AND ".join(where)
        sql += " ORDER BY id DESC LIMIT ?"
        values.append(max(1, min(int(limit), 1000)))
        with self._lock:
            rows = self._conn.execute(sql, values).fetchall()
        out = []
        for row in rows:
            item = dict(zip(_COLUMNS, row))
            item["params"] = json.loads(item["params"] or "{}")
            out.append(item)
        return out


def open_audit() -> AuditLog:
    try:
        from plugins.plugin_storage import plugin_db
    except ImportError:
        return AuditLog(sqlite3.connect(":memory:", check_same_thread=False))
    return AuditLog(plugin_db(PLUGIN_ID, "audit.db"))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/pytest tests/test_audit.py`
Expected: `5 passed`

- [ ] **Step 5: Commit**

```bash
git add sysadmin/audit.py tests/test_audit.py
git commit -m "feat: SQLite audit log with redaction

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Service (single execution path) and runtime

**Files:**
- Create: `sysadmin/service.py`, `sysadmin/runtime.py`, `sysadmin/ops/__init__.py`
- Modify: `tests/conftest.py` (add FakeRunner and service fixtures)
- Test: `tests/test_service.py`, `tests/test_runtime.py`

**Interfaces:**
- Consumes: everything above.
- Produces: `Service` (see README), `runtime.get_service()`, `runtime.notify()`, `runtime.reset()`, `runtime.build_service(settings)`. Test fixtures `FakeRunner`, `settings`, `audit`, `runner`, `events`, `make_service`.

- [ ] **Step 1: Extend fixtures** — replace `tests/conftest.py`

```python
"""Shared test fixtures for hermes-sysadmin."""

import sqlite3

import pytest

from sysadmin.audit import AuditLog
from sysadmin.config import Settings
from sysadmin.registry import OPS, register
from sysadmin.service import Service


class FakeRunner:
    """Records calls. responses[script] may be a value, a callable(params) -> value, or an exception."""

    def __init__(self, responses=None):
        self.responses = dict(responses or {})
        self.calls = []

    def _respond(self, key, params):
        value = self.responses.get(key)
        if isinstance(value, BaseException):
            raise value
        return value(params) if callable(value) else value

    def run(self, script, params, *, retry=False):
        self.calls.append((script, dict(params), retry))
        return self._respond(script, params)

    def run_text(self, text, params):
        self.calls.append(("<text>", {"text": text, **params}, False))
        return self._respond("<text>", params)

    def close(self):
        pass


@pytest.fixture
def scratch_ops():
    """Register temporary ops (names must start with 't_') and remove them afterwards."""
    added = []

    def add(op):
        assert op.name.startswith("t_")
        register(op)
        added.append(op.name)
        return op

    yield add
    for name in added:
        OPS.pop(name, None)


@pytest.fixture
def settings():
    return Settings(host="dc01.corp.example.local", username="CORP\\svc-hermes", password="pw")


@pytest.fixture
def audit():
    return AuditLog(sqlite3.connect(":memory:", check_same_thread=False))


@pytest.fixture
def runner():
    return FakeRunner()


@pytest.fixture
def events():
    return []


@pytest.fixture
def make_service(settings, audit, runner, events):
    def make(**overrides):
        return Service(
            overrides.pop("settings", settings),
            overrides.pop("runner", runner),
            audit,
            notify=lambda event, payload: events.append((event, payload)),
            **overrides,
        )

    return make
```

- [ ] **Step 2: Write the failing test** — `tests/test_service.py`

```python
import pytest

from sysadmin.config import Settings
from sysadmin.errors import NotFound
from sysadmin.registry import Op, Param


@pytest.fixture
def ops(scratch_ops):
    p = (Param("identity", "string", "x", required=True), Param("password", "string", "pw"))
    return {
        "read": scratch_ops(Op("t_s_read", "t", "R", "t_s_read", "d", params=p[:1], cache_ttl=30)),
        "read_nocache": scratch_ops(Op("t_s_read2", "t", "R", "t_s_read2", "d", params=p[:1])),
        "write": scratch_ops(Op("t_s_write", "t", "W", "t_s_write", "d", params=p, identities=("identity",))),
        "high": scratch_ops(Op("t_s_high", "t", "H", "t_s_high", "d", params=p[:1], identities=("identity",), preview=True)),
        "post": scratch_ops(Op("t_s_post", "t", "R", "t_s_post", "d", post=lambda data, args, s: {"n": len(data["items"])})),
        "esc": scratch_ops(Op("t_s_esc", "t", "W", "t_s_esc", "d", params=p[:1], escalate=lambda a, s, f: True)),
    }


def test_read_runs_with_retry_and_no_audit(ops, make_service, runner, audit):
    runner.responses["t_s_read2"] = {"name": "bob"}
    result = make_service().call("t_s_read2", {"identity": "bob"}, actor="agent")
    assert result == {"ok": True, "data": {"name": "bob"}}
    assert runner.calls == [("t_s_read2", {"Identity": "bob"}, True)]
    assert audit.query() == []


def test_write_without_approval_is_refused_and_not_run(ops, make_service, runner, audit):
    result = make_service().call("t_s_write", {"identity": "bob"}, actor="agent")
    assert result["ok"] is False and result["error"]["type"] == "ApprovalRequired"
    assert runner.calls == []
    assert audit.query() == []


def test_approved_write_runs_audits_notifies_and_invalidates(ops, make_service, runner, audit, events):
    runner.responses["t_s_read"] = {"v": 1}
    runner.responses["t_s_write"] = {"done": True}
    svc = make_service()
    svc.call("t_s_read", {"identity": "bob"}, actor="agent")
    result = svc.call("t_s_write", {"identity": "bob", "password": "S3cret!"}, actor="agent", session="s1", approved=True)
    assert result == {"ok": True, "data": {"done": True}}
    assert runner.calls[-1] == ("t_s_write", {"Identity": "bob", "Password": "S3cret!"}, False)
    row = audit.query()[0]
    assert (row["actor"], row["session"], row["tool"], row["target"], row["tier"], row["decision"], row["result"]) == (
        "agent", "s1", "t_s_write", "bob", "W", "approved", "ok",
    )
    assert row["params"]["password"] == "[redacted]"
    assert events == [("changed", {"op": "t_s_write", "target": "bob", "actor": "agent"})]
    svc.call("t_s_read", {"identity": "bob"}, actor="agent")
    assert [c[0] for c in runner.calls].count("t_s_read") == 2


def test_dashboard_write_records_confirmed(ops, make_service, runner, audit):
    runner.responses["t_s_write"] = {}
    make_service().call("t_s_write", {"identity": "bob"}, actor="dashboard", approved=True)
    assert audit.query()[0]["decision"] == "confirmed"


def test_permissive_write_runs_without_approval(ops, make_service, runner, audit):
    runner.responses["t_s_write"] = {}
    svc = make_service(settings=Settings(host="h", username="u", password="p", mode="permissive"))
    assert svc.call("t_s_write", {"identity": "bob"}, actor="agent")["ok"] is True
    assert audit.query()[0]["decision"] == "allowed"


def test_read_only_mode_blocks_and_audits(ops, make_service, runner, audit):
    svc = make_service(settings=Settings(host="h", username="u", password="p", mode="read-only"))
    result = svc.call("t_s_write", {"identity": "bob"}, actor="agent", approved=True)
    assert result["error"]["type"] == "PolicyBlocked"
    assert runner.calls == []
    assert audit.query()[0]["decision"].startswith("blocked: ")


def test_protected_identity_blocked_even_when_approved(ops, make_service, runner, audit):
    result = make_service().call("t_s_high", {"identity": "krbtgt"}, actor="agent", approved=True)
    assert result["error"]["type"] == "PolicyBlocked"
    assert audit.query()[0]["tier"] == "P"
    assert runner.calls == []


def test_failed_write_is_audited_with_message(ops, make_service, runner, audit):
    runner.responses["t_s_write"] = NotFound("No user bob")
    result = make_service().call("t_s_write", {"identity": "bob"}, actor="agent", approved=True)
    assert result["error"]["type"] == "NotFound"
    assert audit.query()[0]["result"] == "failed: No user bob"


def test_read_cache_hits_within_ttl(ops, make_service, runner):
    now = {"t": 0.0}
    runner.responses["t_s_read"] = {"v": 1}
    svc = make_service(clock=lambda: now["t"])
    svc.call("t_s_read", {"identity": "bob"}, actor="dashboard")
    now["t"] = 10
    svc.call("t_s_read", {"identity": "bob"}, actor="dashboard")
    now["t"] = 31
    svc.call("t_s_read", {"identity": "bob"}, actor="dashboard")
    assert [c[0] for c in runner.calls].count("t_s_read") == 2


def test_post_processing_applies(ops, make_service, runner):
    runner.responses["t_s_post"] = {"items": [1, 2, 3]}
    assert make_service().call("t_s_post", {}, actor="agent")["data"] == {"n": 3}


def test_escalation_records_high_tier(ops, make_service, runner, audit):
    runner.responses["t_s_esc"] = {}
    make_service().call("t_s_esc", {"identity": "bob"}, actor="agent", approved=True)
    assert audit.query()[0]["tier"] == "H"


def test_inject_adds_settings_derived_params(scratch_ops, make_service, runner):
    scratch_ops(Op("t_s_inj", "t", "R", "t_s_inj", "d", inject=lambda s: {"Host": s.host}))
    runner.responses["t_s_inj"] = 1
    make_service().call("t_s_inj", {}, actor="agent")
    assert runner.calls == [("t_s_inj", {"Host": "dc01.corp.example.local"}, True)]


def test_preview_runs_script_with_preview_switch(ops, make_service, runner):
    runner.responses["t_s_high"] = {"summary": "Delete bob"}
    assert make_service().preview("t_s_high", {"identity": "bob"}) == {"ok": True, "data": {"summary": "Delete bob"}}
    assert runner.calls == [("t_s_high", {"Identity": "bob", "Preview": True}, True)]


def test_preview_for_op_without_script_preview_describes_args(ops, make_service, runner):
    result = make_service().preview("t_s_write", {"identity": "bob", "password": "x"})
    assert result["data"] == {"summary": "t_s_write on bob", "details": {"identity": "bob", "password": "[redacted]"}}
    assert runner.calls == []


def test_preview_of_protected_target_is_blocked(ops, make_service):
    assert make_service().preview("t_s_high", {"identity": "krbtgt"})["error"]["type"] == "PolicyBlocked"


def test_unknown_op_and_bad_args_are_invalid_arguments(ops, make_service):
    svc = make_service()
    assert svc.call("nope", {}, actor="agent")["error"]["type"] == "InvalidArguments"
    assert svc.call("t_s_write", {}, actor="agent")["error"]["type"] == "InvalidArguments"


def test_record_denied_audits_writes_only(ops, make_service, audit):
    svc = make_service()
    svc.record_denied("t_s_read", {"identity": "bob"}, actor="agent", session="s", reason="user")
    svc.record_denied("t_s_write", {"identity": "bob"}, actor="agent", session="s", reason="by user")
    rows = audit.query()
    assert len(rows) == 1 and rows[0]["decision"] == "denied: by user"


def test_unexpected_exception_becomes_internal_error(ops, make_service, runner):
    runner.responses["t_s_read2"] = RuntimeError("kaboom")
    assert make_service().call("t_s_read2", {"identity": "b"}, actor="agent")["error"]["type"] == "InternalError"


def test_facts_domain_controllers_none_when_lookup_unavailable(ops, make_service, runner):
    from sysadmin.errors import ConnectionFailed

    runner.responses["ad_dc_list"] = ConnectionFailed("down")  # used once ad_dc_list exists (Phase 2)
    assert make_service().facts.domain_controllers() is None
```

- [ ] **Step 3: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_service.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'sysadmin.service'`

- [ ] **Step 4: Implement** — `sysadmin/service.py`

```python
"""The single execution path for every operation (agent tools, hooks, commands, dashboard)."""

from __future__ import annotations

import json
import logging
import threading
import time
from typing import Any, Callable, Mapping

from .audit import AuditLog, redact
from .errors import ApprovalRequired, InvalidArguments, PolicyBlocked, SysadminError, error_result
from .policy import Decision, decide
from .registry import OPS, Op, coerce_args, ps_params, target_of

log = logging.getLogger(__name__)
_NOT_AUDITED = (InvalidArguments, ApprovalRequired)


def _decision_word(decision: Decision, actor: str) -> str:
    if decision.action == "allow":
        return "allowed"
    return "confirmed" if actor == "dashboard" else "approved"


class _Facts:
    """Lazily-resolved domain facts used by escalation rules. None means unknown (fail safe)."""

    def __init__(self, service: "Service") -> None:
        self._service = service
        self._dcs: list[str] | None = None
        self._loaded = False

    def domain_controllers(self) -> list[str] | None:
        if not self._loaded:
            self._loaded = True
            try:
                data = self._service._run_cached(self._service._op("ad_dc_list"), {})
                self._dcs = [str(d["name"]) for d in (data or {}).get("items", [])]
            except Exception:
                self._dcs = None
        return self._dcs


class Service:
    def __init__(
        self,
        settings: Any,
        runner: Any,
        audit: AuditLog,
        notify: Callable[[str, dict], None] | None = None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.settings = settings
        self.runner = runner
        self.audit = audit
        self._notify = notify or (lambda event, payload: None)
        self._clock = clock
        self._cache: dict[str, tuple[float, Any]] = {}
        self._lock = threading.Lock()
        self.facts = _Facts(self)

    # ---- public API -------------------------------------------------------

    def decision(self, name: str, args: Mapping[str, Any] | None = None) -> Decision:
        op = self._op(name)
        return decide(op, coerce_args(op, args), self.settings, self.facts)

    def call(
        self, name: str, args: Mapping[str, Any] | None = None, *,
        actor: str, session: str = "", approved: bool = False,
    ) -> dict[str, Any]:
        op: Op | None = None
        clean: dict[str, Any] = {}
        tier = "W"
        word = "attempted"
        try:
            op = self._op(name)
            clean = coerce_args(op, args)
            d = decide(op, clean, self.settings, self.facts)
            tier, word = d.tier, _decision_word(d, actor)
            if d.action == "block":
                self._audit(op, clean, actor, session, d.tier, f"blocked: {d.reason}", "-")
                raise PolicyBlocked(d.reason)
            if d.action == "approve" and not approved:
                raise ApprovalRequired(f"{op.name} needs approval before it can run.")
            data = self._execute(op, clean)
            if op.tier != "R":
                self._audit(op, clean, actor, session, d.tier, word, "ok")
                self.invalidate()
                self._safe_notify("changed", {"op": op.name, "target": target_of(op, clean), "actor": actor})
            return {"ok": True, "data": data}
        except PolicyBlocked as exc:
            return error_result(exc)
        except SysadminError as exc:
            if op is not None and op.tier != "R" and not isinstance(exc, _NOT_AUDITED):
                self._audit(op, clean, actor, session, tier, word, f"failed: {exc.message}")
            return error_result(exc)
        except Exception as exc:
            log.exception("hermes-sysadmin: %s failed", name)
            return error_result(exc)

    def preview(self, name: str, args: Mapping[str, Any] | None = None) -> dict[str, Any]:
        try:
            op = self._op(name)
            clean = coerce_args(op, args)
            d = decide(op, clean, self.settings, self.facts)
            if d.action == "block":
                raise PolicyBlocked(d.reason)
            if not op.preview:
                return {"ok": True, "data": {"summary": f"{op.name} on {target_of(op, clean) or 'target'}", "details": redact(clean)}}
            data = self.runner.run(op.script, {**self._params(op, clean), "Preview": True}, retry=True)
            return {"ok": True, "data": data}
        except SysadminError as exc:
            return error_result(exc)
        except Exception as exc:
            log.exception("hermes-sysadmin: preview %s failed", name)
            return error_result(exc)

    def record_denied(self, name: str, args: Mapping[str, Any] | None, *, actor: str, session: str, reason: str) -> None:
        op = OPS.get(name)
        if op is None or op.tier == "R":
            return
        try:
            clean = coerce_args(op, args)
        except InvalidArguments:
            clean = dict(args or {})
        self._audit(op, clean, actor, session, op.tier, f"denied: {reason}", "-")

    def invalidate(self) -> None:
        with self._lock:
            self._cache.clear()

    # ---- internals --------------------------------------------------------

    def _op(self, name: str) -> Op:
        op = OPS.get(name)
        if op is None:
            raise InvalidArguments(f"Unknown operation '{name}'.")
        return op

    def _execute(self, op: Op, clean: dict[str, Any]) -> Any:
        if op.tier == "R":
            return self._run_cached(op, clean)
        return self._run(op, clean)

    def _params(self, op: Op, clean: dict[str, Any]) -> dict[str, Any]:
        params = ps_params(op, clean)
        if op.inject is not None:
            params.update(op.inject(self.settings))
        return params

    def _run(self, op: Op, clean: dict[str, Any]) -> Any:
        data = self.runner.run(op.script, self._params(op, clean), retry=op.tier == "R")
        return op.post(data, clean, self.settings) if op.post else data

    def _run_cached(self, op: Op, clean: dict[str, Any]) -> Any:
        if op.cache_ttl <= 0:
            return self._run(op, clean)
        key = op.name + json.dumps(clean, sort_keys=True, default=str)
        now = self._clock()
        with self._lock:
            hit = self._cache.get(key)
        if hit is not None and now - hit[0] < op.cache_ttl:
            return hit[1]
        data = self._run(op, clean)
        with self._lock:
            self._cache[key] = (now, data)
        return data

    def _audit(self, op: Op, clean: dict[str, Any], actor: str, session: str, tier: str, decision: str, result: str) -> None:
        try:
            self.audit.record(
                actor=actor, session=session, tool=op.name, target=target_of(op, clean),
                tier=tier, decision=decision, result=result, params=clean,
            )
        except Exception:
            log.exception("hermes-sysadmin: audit write failed")

    def _safe_notify(self, event: str, payload: dict[str, Any]) -> None:
        try:
            self._notify(event, payload)
        except Exception:
            log.debug("hermes-sysadmin: notify failed", exc_info=True)
```

- [ ] **Step 5: Run service tests**

Run: `.venv/bin/pytest tests/test_service.py`
Expected: `19 passed`

- [ ] **Step 6: Write runtime test** — `tests/test_runtime.py`

```python
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
```

- [ ] **Step 7: Implement** — `sysadmin/ops/__init__.py`

```python
"""Importing this package registers every operation in sysadmin.registry.OPS.

Each surface module is imported below as it is added (Phase 2 onwards).
"""
```

`sysadmin/runtime.py`:
```python
"""Process-wide Service instance, rebuilt whenever the plugin settings change."""

from __future__ import annotations

import logging
import threading
from contextlib import suppress
from typing import Any

from . import PLUGIN_ID
from . import ops as _ops  # noqa: F401  (registers operations)
from .audit import AuditLog, open_audit
from .config import Settings, load_settings
from .runner import Runner, load_prelude
from .service import Service
from .transport import PsrpTransport, UnconfiguredTransport

log = logging.getLogger(__name__)
_lock = threading.Lock()
_state: dict[str, Any] = {"settings": None, "service": None}
_audit: AuditLog | None = None


def notify(event: str, payload: dict) -> None:
    try:
        from hermes_cli.plugin_events import broadcast_plugin_event

        broadcast_plugin_event(PLUGIN_ID, event, payload)
    except Exception:
        log.debug("hermes-sysadmin: event broadcast unavailable", exc_info=True)


def _audit_log() -> AuditLog:
    global _audit
    if _audit is None:
        _audit = open_audit()
    return _audit


def build_service(settings: Settings) -> Service:
    transport = PsrpTransport(settings, load_prelude()) if settings.configured else UnconfiguredTransport()
    return Service(settings, Runner(transport), _audit_log(), notify=notify)


def get_service() -> Service:
    settings = load_settings()
    with _lock:
        current = _state["service"]
        if current is not None and _state["settings"] == settings:
            return current
        if current is not None:
            with suppress(Exception):
                current.runner.close()
        service = build_service(settings)
        _state.update(settings=settings, service=service)
        return service


def reset() -> None:
    with _lock:
        current = _state["service"]
        if current is not None:
            with suppress(Exception):
                current.runner.close()
        _state.update(settings=None, service=None)
```

- [ ] **Step 8: Run the full suite**

Run: `.venv/bin/pytest`
Expected: all tests pass (`93 passed`).

- [ ] **Step 9: Commit**

```bash
git add sysadmin/service.py sysadmin/runtime.py sysadmin/ops/__init__.py tests/conftest.py tests/test_service.py tests/test_runtime.py
git commit -m "feat: service execution path and runtime

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
