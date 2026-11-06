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
