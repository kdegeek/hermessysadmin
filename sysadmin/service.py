"""The single execution path for every operation (agent tools, hooks, commands, dashboard)."""

from __future__ import annotations

import copy
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
FACTS_TTL = 300.0
_NOT_AUDITED = (InvalidArguments, ApprovalRequired)


def _decision_word(decision: Decision, actor: str) -> str:
    if decision.action == "allow":
        return "allowed"
    return "confirmed" if actor == "dashboard" else "approved"


class _Facts:
    """Lazily-resolved domain facts used by escalation rules. None means unknown (fail safe)."""

    def __init__(self, service: "Service") -> None:
        self._service = service
        self._dcs: tuple[float, list[str]] | None = None

    def clear(self) -> None:
        self._dcs = None

    def domain_controllers(self) -> list[str] | None:
        svc = self._service
        now = svc._clock()
        cached = self._dcs
        if cached is not None and now - cached[0] < FACTS_TTL:
            return list(cached[1])
        gen = svc._generation
        try:
            data = svc._run_cached(svc._op("ad_dc_list"), {})
            dcs = [str(d["name"]) for d in (data or {}).get("items", [])]
        except Exception:
            return None  # unknown; do not latch, retry next call
        if svc._generation == gen:
            self._dcs = (now, dcs)
        return list(dcs)


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
        self._generation = 0
        self._on_invalidate: list[Callable[[], None]] = []
        self.facts = _Facts(self)

    # ---- public API -------------------------------------------------------

    def decision(self, name: str, args: Mapping[str, Any] | None = None) -> Decision:
        op = self._op(name)
        return decide(op, coerce_args(op, args), self.settings, self.facts)

    def call(
        self, name: str, args: Mapping[str, Any] | None = None, *,
        actor: str, session: str = "", approved: bool | str = False, fresh: bool = False,
    ) -> dict[str, Any]:
        """Run one op through policy. fresh=True skips the read cache (and stores the new result)."""
        op: Op | None = None
        clean: dict[str, Any] = {}
        tier = "W"
        word = "attempted"
        try:
            op = self._op(name)
            tier = op.tier
            clean = coerce_args(op, args)
            d = decide(op, clean, self.settings, self.facts)
            tier, word = d.tier, _decision_word(d, actor)
            if d.action == "block":
                self._audit(op, clean, actor, session, d.tier, f"blocked: {d.reason}", "-")
                raise PolicyBlocked(d.reason)
            if d.action == "approve" and not approved:
                raise ApprovalRequired(f"{op.name} needs approval before it can run.")
            if d.action == "approve" and approved == "W" and d.tier == "H":
                # The human approved a write-tier change; the live decision escalated to high-risk since.
                raise ApprovalRequired(
                    f"{op.name} became high-risk after it was approved; approve it again.", tier=d.tier,
                )
            try:
                data = self._execute(op, clean, fresh=fresh)
            except PolicyBlocked as exc:
                # The script refused after resolving the real object (e.g. an aliased krbtgt).
                self._audit(op, clean, actor, session, tier, f"blocked: {exc.message}", "-")
                raise
            finally:
                if d.tier != "R":
                    self.invalidate()
            if d.tier != "R":
                self._audit(op, clean, actor, session, d.tier, word, "ok")
                self._safe_notify("changed", {"op": op.name, "target": target_of(op, clean), "actor": actor})
            return {"ok": True, "data": data}
        except PolicyBlocked as exc:
            return error_result(exc)
        except SysadminError as exc:
            if op is not None and tier != "R" and not isinstance(exc, _NOT_AUDITED):
                self._audit(op, clean, actor, session, tier, word, f"failed: {exc.message}")
            return error_result(exc)
        except Exception as exc:
            log.exception("hermes-sysadmin: %s failed", name)
            if op is not None and tier != "R":
                self._audit(op, clean, actor, session, tier, word, f"failed: {type(exc).__name__}")
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
            if op.local is not None:
                if op.local_preview is None:
                    return {"ok": True, "data": {"summary": f"{op.name} on {target_of(op, clean) or 'target'}", "details": redact(clean)}}
                return {"ok": True, "data": op.local_preview(self, clean)}
            data = self.runner.run(op.script, {**self._params(op, clean), "Preview": True}, retry=op.tier == "R")
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
            self._generation += 1
            self.facts.clear()
            listeners = list(self._on_invalidate)
        for fn in listeners:
            try:
                fn()
            except Exception:
                log.debug("hermes-sysadmin: invalidate listener failed", exc_info=True)

    def on_invalidate(self, fn: Callable[[], None]) -> None:
        """Call fn after every invalidate (a write, a refresh): the dashboard snapshots go stale."""
        with self._lock:
            self._on_invalidate.append(fn)

    # ---- internals --------------------------------------------------------

    def _op(self, name: str) -> Op:
        op = OPS.get(name)
        if op is None:
            raise InvalidArguments(f"Unknown operation '{name}'.")
        return op

    def _execute(self, op: Op, clean: dict[str, Any], fresh: bool = False) -> Any:
        if op.tier == "R":
            return self._run_cached(op, clean, fresh=fresh)
        return self._run(op, clean)

    def _params(self, op: Op, clean: dict[str, Any]) -> dict[str, Any]:
        params = ps_params(op, clean)
        if op.inject is not None:
            params.update(op.inject(self.settings))
        return params

    def _run(self, op: Op, clean: dict[str, Any]) -> Any:
        if op.local is not None:
            data = op.local(self, clean)
        else:
            data = self.runner.run(op.script, self._params(op, clean), retry=op.tier == "R")
        return op.post(data, clean, self.settings) if op.post else data

    def _run_cached(self, op: Op, clean: dict[str, Any], fresh: bool = False) -> Any:
        if op.cache_ttl <= 0:
            return self._run(op, clean)
        # refresh=true skips the lookup but still stores the result; it is not part of the cache key.
        key = op.name + json.dumps({k: v for k, v in clean.items() if k != "refresh"}, sort_keys=True, default=str)
        now = self._clock()
        if clean.get("refresh") is not True and not fresh:
            with self._lock:
                hit = self._cache.get(key)
            if hit is not None and now - hit[0] < op.cache_ttl:
                return copy.deepcopy(hit[1])
        with self._lock:
            gen = self._generation
        data = self._run(op, clean)
        with self._lock:
            if self._generation == gen:
                self._cache[key] = (now, copy.deepcopy(data))
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
