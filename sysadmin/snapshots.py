"""Stale-while-revalidate snapshots for the dashboard's read views.

The dashboard never waits on a probe it has already run once: `get()` answers from the last good
result straight away and, when that result is older than `max_age` (or a write made every snapshot
stale), refreshes it in the background. Concurrent callers for one key share a single refresh.
The response carries a `cache` block (age, collection time, whether a refresh is running) so the
page can say how old the data is and poll until the refresh lands.

The first request for a key has nothing to show, so it waits for the result. A failed refresh
keeps the last good result and reports the error in `cache.error`.
"""

from __future__ import annotations

import logging
import threading
import time
from concurrent.futures import Future, ThreadPoolExecutor
from datetime import datetime, timezone
from typing import Any, Callable

log = logging.getLogger(__name__)
Producer = Callable[[], dict[str, Any]]


class _Entry:
    __slots__ = ("result", "mono", "wall", "error")

    def __init__(self, result: dict[str, Any], mono: float, wall: float) -> None:
        self.result = result
        self.mono = mono
        self.wall = wall
        self.error: dict[str, Any] | None = None


class Snapshots:
    def __init__(
        self,
        *,
        workers: int = 4,
        clock: Callable[[], float] = time.monotonic,
        wall: Callable[[], float] = time.time,
    ) -> None:
        self._clock = clock
        self._wall = wall
        self._lock = threading.Lock()
        self._entries: dict[str, _Entry] = {}
        self._inflight: dict[str, Future] = {}
        self._stale_before = float("-inf")
        self._pool = ThreadPoolExecutor(max_workers=workers, thread_name_prefix="hermes-sysadmin-snap")

    # ---- public ------------------------------------------------------------

    def get(self, key: str, producer: Producer, max_age: float, *, refresh: bool = False) -> dict[str, Any]:
        """The snapshot for key, refreshed in the background when stale; waits only when there is none."""
        with self._lock:
            entry = self._entries.get(key)
        if entry is None:
            result = self._start(key, producer).result()
            with self._lock:
                entry = self._entries.get(key)
            if entry is None:  # the first collection failed: nothing to fall back on
                return result
            return self._annotate(key, entry)
        if refresh or self._is_stale(entry, max_age):
            self._start(key, producer)
        return self._annotate(key, entry)

    def collect(self, key: str, producer: Producer) -> dict[str, Any]:
        """Refresh key now and wait for it (the background collector); joins a refresh already running."""
        return self._start(key, producer).result()

    def age(self, key: str) -> float | None:
        """Seconds since key was last collected, or None if never (or made stale by a write)."""
        with self._lock:
            entry = self._entries.get(key)
            if entry is None or entry.mono < self._stale_before:
                return None
            return self._clock() - entry.mono

    def peek(self, key: str) -> dict[str, Any] | None:
        """The last good result for key without refreshing it."""
        with self._lock:
            entry = self._entries.get(key)
        return entry.result if entry is not None else None

    def mark_stale(self) -> None:
        """Every snapshot taken before now refreshes on its next read (after a write)."""
        with self._lock:
            self._stale_before = self._clock()

    def close(self) -> None:
        self._pool.shutdown(wait=False, cancel_futures=True)

    # ---- internals ---------------------------------------------------------

    def _is_stale(self, entry: _Entry, max_age: float) -> bool:
        return entry.mono <= self._stale_before or self._clock() - entry.mono > max_age

    def _start(self, key: str, producer: Producer) -> Future:
        with self._lock:
            running = self._inflight.get(key)
            if running is not None:
                return running
            future: Future = Future()
            self._inflight[key] = future
        try:
            self._pool.submit(self._run, key, producer, future)
        except RuntimeError as exc:  # pool shut down (settings changed mid-request)
            with self._lock:
                self._inflight.pop(key, None)
            future.set_result({"ok": False, "error": {"type": "InternalError", "message": str(exc)}})
        return future

    def _run(self, key: str, producer: Producer, future: Future) -> None:
        started = self._clock()
        try:
            result = producer()
        except Exception as exc:  # producers return envelopes; this is a bug, not a probe failure
            log.exception("hermes-sysadmin: snapshot %s failed", key)
            result = {"ok": False, "error": {"type": "InternalError", "message": f"{type(exc).__name__}: {exc}"}}
        with self._lock:
            if isinstance(result, dict) and result.get("ok"):
                # Stamped with the start time: a write that lands mid-refresh still marks this stale.
                self._entries[key] = _Entry(result, started, self._wall())
            elif key in self._entries:
                self._entries[key].error = (result or {}).get("error") if isinstance(result, dict) else None
            self._inflight.pop(key, None)
        future.set_result(result)

    def _annotate(self, key: str, entry: _Entry) -> dict[str, Any]:
        with self._lock:
            refreshing = key in self._inflight
            age = max(0.0, self._clock() - entry.mono)
            error = entry.error
        cache = {
            "age_s": round(age, 1),
            "collected_at": datetime.fromtimestamp(entry.wall, timezone.utc).isoformat(),
            "refreshing": refreshing,
        }
        if error:
            cache["error"] = error
        return {**entry.result, "cache": cache}
