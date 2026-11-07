"""A small pool of local PowerShell transports, so a slow probe never blocks the next request.

Each member is an ordinary LocalTransport (one persistent PowerShell process). Members are
started on demand, up to `size`, and every call borrows an idle one.

All members share one credential check. The run-as password is validated with LogonUserW once
for the whole pool, and a rejection stops every member, so a wrong password still costs a single
failed logon, not one per process.
"""

from __future__ import annotations

import threading
from contextlib import suppress
from typing import Any, Callable, Mapping

from .config import Settings
from .local_transport import CredentialRejected


class SharedCredentialCheck:
    """Runs `check(settings)` once for every member; latches success or the rejection.

    `invalidate()` forgets a success (a member's network probe failed, so the password may have
    changed in AD): the next start by any member validates again.
    """

    def __init__(self, check: Callable[[Settings], None]) -> None:
        self._check = check
        self._lock = threading.Lock()
        self._ok = False
        self._rejected: CredentialRejected | None = None

    def __call__(self, settings: Settings) -> None:
        with self._lock:
            if self._rejected is not None:
                raise CredentialRejected(self._rejected.message, hint=self._rejected.hint)
            if self._ok:
                return
            try:
                self._check(settings)
            except CredentialRejected as err:
                self._rejected = err
                raise
            self._ok = True

    def invalidate(self) -> None:
        with self._lock:
            self._ok = False


class TransportPool:
    """Borrow-and-return pool over transports made by `factory()`; same interface as one transport."""

    def __init__(self, factory: Callable[[], Any], size: int) -> None:
        self._factory = factory
        self._size = max(1, int(size))
        self._cond = threading.Condition()
        self._idle: list[Any] = []
        self._all: list[Any] = []
        self._closed = False

    @property
    def members(self) -> list[Any]:
        with self._cond:
            return list(self._all)

    def _borrow(self) -> Any:
        with self._cond:
            while True:
                if self._closed:
                    raise RuntimeError("transport pool is closed")
                if self._idle:
                    return self._idle.pop()
                if len(self._all) < self._size:
                    member = self._factory()
                    self._all.append(member)
                    return member
                self._cond.wait()

    def _return(self, member: Any) -> None:
        with self._cond:
            if self._closed:
                with suppress(Exception):
                    member.close()
                return
            self._idle.append(member)
            self._cond.notify()

    def invoke(self, script: str, params: Mapping[str, Any]) -> list[Any]:
        member = self._borrow()
        try:
            return member.invoke(script, params)
        finally:
            self._return(member)

    def close(self) -> None:
        with self._cond:
            self._closed = True
            members, self._all, self._idle = list(self._all), [], []
            self._cond.notify_all()
        for member in members:
            with suppress(Exception):
                member.close()
