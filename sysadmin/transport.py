"""WinRM/PSRP transport: one pooled runspace to the jump host, serialized by a lock."""

from __future__ import annotations

import logging
import threading
from contextlib import suppress
from typing import Any, Callable, Mapping, Protocol

from .config import Settings
from .errors import ConnectionFailed, NotConfigured, RemoteScriptError, SysadminError, Timeout

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
    try:
        from pypsrp.exceptions import WinRMError
    except ImportError:  # pragma: no cover
        WinRMError = ()  # type: ignore[assignment,misc]

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
    if isinstance(exc, (requests.exceptions.RequestException, WinRMError, OSError)):
        return ConnectionFailed(f"WinRM error talking to {host}: {type(exc).__name__}: {text}")
    log.error("Unexpected error talking to %s", host, exc_info=exc)
    return SysadminError(f"Unexpected error talking to {host}: {type(exc).__name__}: {text}")


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
        try:
            pool.open()
            ps = self._ps_factory(pool)
            ps.add_script(self._prelude, use_local_scope=False)
            ps.add_parameter("User", self._settings.username)
            ps.add_parameter("Pass", self._settings.password)
            ps.invoke()
            if ps.had_errors:
                message = str(ps.streams.error[0]) if ps.streams.error else "prelude failed"
                raise RemoteScriptError(f"Session setup failed on {self._settings.host}: {message}")
        except BaseException:
            with suppress(Exception):
                pool.close()
            raise
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
