"""Background collector: keeps the dashboard snapshots warm so every view opens instantly.

It runs in the gateway (started by the first dashboard request) on one thread, so it uses at
most one PowerShell worker at a time and clicks always find a free one. While the dashboard is
in use it refreshes the overview every minute, the fleet every five minutes and every online
computer's drawer every twenty. When nobody has used the dashboard for twenty minutes it slows
down and skips the per-computer sweep.

Read-only by construction: it only calls read views (api.warm / api.warm_device), which go
through the service and its policy like any other read.
"""

from __future__ import annotations

import logging
import os
import threading
import time
from typing import Any, Callable

log = logging.getLogger(__name__)

#: How long after the last dashboard request the collector stays in its active schedule.
ACTIVE_WINDOW = 1200.0
TICK = 5.0
#: Seconds between collections: (while the dashboard is in use, while idle). None = skip when idle.
SCHEDULE: dict[str, tuple[float, float | None]] = {
    "health": (60.0, 600.0),
    "overview": (60.0, 600.0),
    "monitoring": (60.0, 600.0),
    "fleet": (300.0, 1800.0),
    "devices": (1200.0, None),
}
ORDER = ("health", "overview", "monitoring", "fleet", "devices")
DISABLE_ENV = "HERMES_SYSADMIN_COLLECTOR"


class Collector:
    def __init__(
        self,
        get_service: Callable[[], Any],
        api: Any,
        *,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._get_service = get_service
        self._api = api
        self._clock = clock
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._last_activity = float("-inf")
        self._last_run: dict[str, float] = {}
        self._service: Any = None
        self._failed_this_sweep: set[str] = set()

    # ---- control -----------------------------------------------------------

    def touch(self) -> None:
        """A dashboard request arrived: use the active schedule."""
        self._last_activity = self._clock()

    def ensure_started(self) -> bool:
        """Start the collector thread once (unless HERMES_SYSADMIN_COLLECTOR=0)."""
        if os.environ.get(DISABLE_ENV, "1").strip().lower() in ("0", "false", "no", "off"):
            return False
        with self._lock:
            if self._thread is not None and self._thread.is_alive():
                return True
            self._stop.clear()
            self._thread = threading.Thread(target=self._loop, name="hermes-sysadmin-collector", daemon=True)
            self._thread.start()
            return True

    def stop(self) -> None:
        self._stop.set()

    # ---- work --------------------------------------------------------------

    def active(self) -> bool:
        return self._clock() - self._last_activity < ACTIVE_WINDOW

    def due(self, task: str, now: float) -> bool:
        active_every, idle_every = SCHEDULE[task]
        every = active_every if self.active() else idle_every
        if every is None:
            return False
        last = self._last_run.get(task)
        return last is None or now - last >= every

    def run_once(self) -> list[str]:
        """Run every task that is due; returns their names (one pass of the loop)."""
        service = self._get_service()
        if service is not self._service:  # settings changed: a new service starts with empty snapshots
            self._service = service
            self._last_run.clear()
        if not getattr(service.settings, "configured", False):
            return []
        ran = []
        for task in ORDER:
            if self._stop.is_set():
                break
            now = self._clock()
            if not self.due(task, now):
                continue
            try:
                if task == "devices":
                    # One computer per pass, so the overview keeps its one-minute cadence during a sweep.
                    if self._sweep_step(service):
                        ran.append(task)
                        continue
                else:
                    self._api.warm(service, task)
            except Exception:
                log.exception("hermes-sysadmin: background collection of %s failed", task)
            self._last_run[task] = now
            ran.append(task)
        return ran

    def _sweep_step(self, service: Any) -> bool:
        """Collect the next online computer whose drawer snapshot is missing or older than the sweep
        interval. False when every computer is fresh (the sweep is complete)."""
        every = SCHEDULE["devices"][0]
        snap = self._api.snapshots(service)
        for name in self._api.online_computers(service):
            if name.lower() in self._failed_this_sweep:
                continue
            key = self._api.device_key(name)
            age = snap.age(key)
            if age is not None and age < every:
                continue
            try:
                self._api.warm_device(service, name)
            except Exception:
                log.exception("hermes-sysadmin: background collection of %s failed", name)
            if snap.age(key) is None or snap.age(key) >= every:
                # The probe failed (the old snapshot, if any, is kept): do not retry it this sweep.
                self._failed_this_sweep.add(name.lower())
            return True
        self._failed_this_sweep.clear()
        return False

    def _loop(self) -> None:
        while not self._stop.is_set():
            try:
                self.run_once()
            except Exception:
                log.exception("hermes-sysadmin: background collector pass failed")
            self._stop.wait(TICK)
