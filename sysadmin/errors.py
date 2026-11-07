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
        "Open Settings → Plugins → hermes-sysadmin. WinRM transport: set the jump host, username and password. "
        "Local transport: choose 'Run as'; running as an account also needs its username and password."
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


class NotInstalled(SysadminError):
    type = "NotInstalled"
    default_hint = "Install the pinned module with catalog_module_install."


class PartialResult(SysadminError):
    type = "PartialResult"
    default_hint = "Some hosts did not answer; the rows that did are included."


ERROR_TYPES: dict[str, type[SysadminError]] = {
    cls.type: cls
    for cls in (
        NotConfigured, ConnectionFailed, PermissionDenied, NotFound, PolicyBlocked,
        ApprovalRequired, RemoteScriptError, Timeout, InvalidArguments, NotInstalled, PartialResult,
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
