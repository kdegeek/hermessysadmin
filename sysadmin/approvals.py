"""Hands the tier the pre_tool_call hook approved to the tool handler that runs next.

Hermes gives the hook the tool-call id but not the handler, so a grant is keyed by session, tool and
the exact arguments. The handler takes the grant (once) and passes the tier to Service.call, which
refuses when the live decision is stricter than what the human approved. No grant means nothing was
approved: the call runs only if policy no longer asks for approval.
"""

from __future__ import annotations

import json
import threading
import time
from typing import Any, Mapping

TTL = 600.0  # seconds a grant waits for its handler (an approval prompt can sit open for a while)
_lock = threading.Lock()
_grants: dict[str, tuple[str, float]] = {}


def session_of(kwargs: Mapping[str, Any]) -> str:
    return str(kwargs.get("session_id") or kwargs.get("task_id") or "")


def _key(session: str, tool: str, args: Mapping[str, Any] | None) -> str:
    return json.dumps([session, tool, dict(args or {})], sort_keys=True, default=str)


def _prune(now: float) -> None:
    for k in [k for k, (_, t) in _grants.items() if now - t > TTL]:
        del _grants[k]


def grant(session: str, tool: str, args: Mapping[str, Any] | None, tier: str | None) -> None:
    """Record the tier the hook asked the human to approve (None clears any earlier grant)."""
    now = time.monotonic()
    with _lock:
        _prune(now)
        k = _key(session, tool, args)
        if tier:
            _grants[k] = (tier, now)
        else:
            _grants.pop(k, None)


def take(session: str, tool: str, args: Mapping[str, Any] | None) -> str | bool:
    """The approved tier for this call ("W" or "H"), or False when the hook approved nothing."""
    now = time.monotonic()
    with _lock:
        _prune(now)
        hit = _grants.pop(_key(session, tool, args), None)
    return hit[0] if hit else False


def clear() -> None:
    with _lock:
        _grants.clear()
