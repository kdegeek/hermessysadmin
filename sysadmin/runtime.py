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
    global _audit
    with _lock:
        _audit = None
        current = _state["service"]
        if current is not None:
            with suppress(Exception):
                current.runner.close()
        _state.update(settings=None, service=None)
