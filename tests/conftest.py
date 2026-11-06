"""Shared test fixtures for hermes-sysadmin."""

import pytest

from sysadmin.registry import OPS, register


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
