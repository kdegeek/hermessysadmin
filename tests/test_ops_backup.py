from datetime import datetime, timezone

import pytest

from sysadmin import ops  # noqa: F401
from sysadmin.config import Settings
from sysadmin.errors import InvalidArguments
from sysadmin.ops.backup import backup_state, event_outcome, parse_iso, status_summary
from sysadmin.policy import decide
from sysadmin.registry import OPS, coerce_args, ps_params

NOW = datetime(2026, 11, 5, 12, 0, tzinfo=timezone.utc)

EXPECTED = {
    "backup_status": ("R", False), "backup_versions": ("R", False), "backup_jobs": ("R", False),
    "backup_start": ("W", False), "backup_cancel": ("W", False), "backup_set_policy": ("H", True),
}

HEALTHY = {
    "host": "DC01", "installed": True, "policy": True, "last_result_hr": 0, "message": "",
    "versions": 14, "last_system_state": "2026-11-05T02:00:00.0000000Z", "job": None,
}


@pytest.mark.parametrize("name", sorted(EXPECTED))
def test_tiers(name):
    assert (OPS[name].tier, OPS[name].preview) == EXPECTED[name]
    assert OPS[name].toolset == "ad_backup"


def test_parse_iso_handles_dotnet_round_trip_format():
    assert parse_iso("2026-11-05T02:00:00.1234567Z") == datetime(2026, 11, 5, 2, 0, 0, 123456, tzinfo=timezone.utc)
    assert parse_iso("2026-11-05T02:00:00Z") == datetime(2026, 11, 5, 2, 0, tzinfo=timezone.utc)
    assert parse_iso(None) is None and parse_iso("not a date") is None


@pytest.mark.parametrize(
    "changes, state, stale, message",
    [
        ({}, "ok", False, ""),
        ({"last_system_state": "2026-10-27T23:00:00Z"}, "bad", True, "System-state backup is 8.5 days old"),
        ({"last_system_state": None}, "bad", True, "No system-state backup found"),
        ({"last_result_hr": -2139619131, "message": "The backup target volume was not found."}, "bad", False,
         "The backup target volume was not found."),
        ({"last_result_hr": -2139619131}, "bad", False, "Last backup failed (0x807800C5)"),
        ({"job": {"running": True, "percent": 62}}, "run", False, ""),
        ({"installed": False}, "none", False, "Windows Server Backup feature not installed"),
        ({"policy": False, "versions": 0, "last_system_state": None}, "none", False, "No backup policy configured"),
    ],
)
def test_backup_state(changes, state, stale, message):
    out = backup_state({**HEALTHY, **changes}, 7, NOW)
    assert (out["state"], out["stale"], out["message"]) == (state, stale, message)


def test_backup_state_age_hours():
    assert backup_state(HEALTHY, 7, NOW)["age_hours"] == 10.0


def test_status_post_summary_and_oldest():
    data = {
        "results": [
            HEALTHY,
            {**HEALTHY, "host": "SRV-FS01", "last_system_state": "2026-10-27T12:00:00Z"},
            {**HEALTHY, "host": "SRV-RDS01", "installed": False},
        ],
        "errors": [{"host": "SRV-OLD", "message": "WinRM cannot complete the operation"}],
    }
    out = status_summary(data, 7, NOW)
    assert [h["state"] for h in out["items"]] == ["ok", "bad", "none"]
    assert out["summary"] == {
        "hosts": 4, "ok": 1, "bad": 1, "running": 0, "not_configured": 1, "unreachable": 1,
        "oldest_system_state": {"host": "SRV-FS01", "age_hours": 216.0},
    }


@pytest.mark.parametrize(
    "event, outcome",
    [
        ({"id": 1, "level": "Information"}, "started"),
        ({"id": 4, "level": "Information"}, "succeeded"),
        ({"id": 14, "level": "Information"}, "completed"),
        ({"id": 5, "level": "Error"}, "failed"),
        ({"id": 100, "level": "Warning"}, "info"),
    ],
)
def test_event_outcome(event, outcome):
    assert event_outcome(event) == outcome


def test_jobs_post_classifies_history():
    out = OPS["backup_jobs"].post({"current": None, "history": [{"id": 4, "level": "Information"}]}, {}, Settings())
    assert out["history"][0]["outcome"] == "succeeded"


def test_start_kind_is_validated_and_host_maps_to_computer_name():
    with pytest.raises(InvalidArguments):
        coerce_args(OPS["backup_start"], {"host": "SRV1", "kind": "everything"})
    args = coerce_args(OPS["backup_start"], {"host": "SRV1"})
    assert args["kind"] == "system_state"
    assert ps_params(OPS["backup_start"], args)["ComputerName"] == "SRV1"
    assert OPS["backup_status"].inject(Settings(server_search_base="OU=S")) == {"ServerSearchBase": "OU=S"}


def test_set_policy_always_needs_preview_approval():
    d = decide(OPS["backup_set_policy"], {"host": "SRV1", "schedule": ["23:00"], "target": "E:"}, Settings())
    assert (d.action, d.tier, d.needs_preview) == ("approve", "H", True)
