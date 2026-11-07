"""Plugin settings: read from config.yaml (plugins.entries.hermes-sysadmin.settings) and Hermes secrets."""

from __future__ import annotations

import functools
import logging
import os
import re
from dataclasses import dataclass, field
from typing import Any, Mapping

from . import PLUGIN_ID

log = logging.getLogger(__name__)

PASSWORD_ENV = "SYSADMIN_WINRM_PASSWORD"
MODES = ("strict", "permissive", "read-only")
AUTHS = ("ntlm", "kerberos")
TRANSPORTS = ("auto", "local", "winrm")
RUN_AS = ("account", "hermes_user")
#: NETSETUP_JOIN_STATUS.NetSetupDomainName from NetGetJoinInformation.
_NETSETUP_DOMAIN_NAME = 3


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
    monitor_interval: str = "30m"
    alert_disk_free_pct: int = 10
    alert_offline_days: int = 7
    alert_patch_age_days: int = 45
    alert_privileged_changes: bool = True
    alert_lockouts: bool = True
    #: Resolved transport: "local" (PowerShell on this machine) or "winrm" (jump host). Never "auto".
    transport: str = "winrm"
    #: Local transport only: "account" (runas /netonly with username + password) or "hermes_user".
    run_as: str = "account"

    @property
    def configured(self) -> bool:
        if self.transport == "local":
            if self.run_as == "hermes_user":
                return True
            return bool(self.username and self.password)
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


_INTERVAL = re.compile(r"\d+[mh]")


def _interval(value: Any, default: str) -> str:
    text = str(value or "").strip().lower()
    return text if _INTERVAL.fullmatch(text) and int(text[:-1]) > 0 else default


def _strings(value: Any) -> tuple[str, ...]:
    if isinstance(value, str):
        items = value.replace("\n", ",").split(",")
    elif isinstance(value, (list, tuple)):
        items = [str(v) for v in value]
    else:
        items = []
    return tuple(s.strip() for s in items if s and s.strip())


def _os_name() -> str:
    return os.name


@functools.lru_cache(maxsize=1)
def _domain_joined() -> bool:
    """True when this Windows machine is joined to an AD domain (NetGetJoinInformation)."""
    if _os_name() != "nt":
        return False
    try:
        import ctypes
        from ctypes import wintypes

        netapi32 = ctypes.WinDLL("netapi32")
        name = wintypes.LPWSTR()
        status = wintypes.DWORD()
        rc = netapi32.NetGetJoinInformation(None, ctypes.byref(name), ctypes.byref(status))
        if name:
            netapi32.NetApiBufferFree(name)
        return rc == 0 and status.value == _NETSETUP_DOMAIN_NAME
    except Exception:
        log.debug("hermes-sysadmin: domain join check failed", exc_info=True)
        return False


def _transport(value: Any) -> str:
    choice = _choice(value, TRANSPORTS, "auto")
    if choice != "auto":
        return choice
    return "local" if _os_name() == "nt" and _domain_joined() else "winrm"


def settings_from(raw: Mapping[str, Any] | None, password: str) -> Settings:
    raw = raw or {}
    use_https = _bool(raw.get("use_https"), True)
    return Settings(
        transport=_transport(raw.get("transport")),
        run_as=_choice(raw.get("run_as"), RUN_AS, "account"),
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
        monitor_interval=_interval(raw.get("monitor_interval"), "30m"),
        alert_disk_free_pct=_int(raw.get("alert_disk_free_pct"), 10, 1, 90),
        alert_offline_days=_int(raw.get("alert_offline_days"), 7, 1, 365),
        alert_patch_age_days=_int(raw.get("alert_patch_age_days"), 45, 1, 365),
        alert_privileged_changes=_bool(raw.get("alert_privileged_changes"), True),
        alert_lockouts=_bool(raw.get("alert_lockouts"), True),
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
