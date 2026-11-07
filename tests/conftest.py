"""Shared test fixtures for hermes-sysadmin."""

import os
import sqlite3

# Tests drive the dashboard routes directly; no background collector thread.
os.environ["HERMES_SYSADMIN_COLLECTOR"] = "0"

import pytest

from sysadmin.audit import AuditLog
from sysadmin.config import Settings
from sysadmin.registry import OPS, register
from sysadmin.service import Service


class FakeRunner:
    """Records calls. responses[script] may be a value, a callable(params) -> value, or an exception."""

    def __init__(self, responses=None):
        self.responses = dict(responses or {})
        self.calls = []

    def _respond(self, key, params):
        value = self.responses.get(key)
        if isinstance(value, BaseException):
            raise value
        return value(params) if callable(value) else value

    def run(self, script, params, *, retry=False):
        self.calls.append((script, dict(params), retry))
        return self._respond(script, params)

    def run_text(self, text, params):
        self.calls.append(("<text>", {"text": text, **params}, False))
        return self._respond("<text>", params)

    def close(self):
        pass


@pytest.fixture
def scratch_ops():
    """Register temporary ops (names must start with 't_') and remove them afterwards."""
    added = []

    def add(op):
        assert op.name.startswith("t_")
        register(op)
        added.append(op.name)
        return op

    yield add
    for name in added:
        OPS.pop(name, None)


@pytest.fixture
def settings():
    return Settings(host="dc01.corp.example.local", username="CORP\\svc-hermes", password="pw")


@pytest.fixture
def audit():
    return AuditLog(sqlite3.connect(":memory:", check_same_thread=False))


@pytest.fixture
def runner():
    return FakeRunner()


@pytest.fixture
def events():
    return []


@pytest.fixture
def make_service(settings, audit, runner, events):
    def make(**overrides):
        return Service(
            overrides.pop("settings", settings),
            overrides.pop("runner", runner),
            audit,
            notify=lambda event, payload: events.append((event, payload)),
            **overrides,
        )

    return make
