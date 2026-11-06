import pytest

from sysadmin import ops  # noqa: F401
from sysadmin.config import Settings
from sysadmin.ops.domain import dc_status, worst
from sysadmin.registry import OPS, coerce_args

HEALTHY = {
    "reachable": True,
    "services": {"NTDS": "Running", "Netlogon": "Running", "KDC": "Running", "DNS": "Running", "W32Time": "Running"},
    "sysvol_shared": True,
    "netlogon_shared": True,
    "time_skew_seconds": 0.4,
    "replication": {"failures": 0},
}


def with_(**changes):
    dc = {**HEALTHY, **changes}
    return dc


@pytest.mark.parametrize(
    "dc, expected",
    [
        (HEALTHY, "ok"),
        (with_(reachable=False), "bad"),
        (with_(services={**HEALTHY["services"], "NTDS": "Stopped"}), "bad"),
        (with_(services={**HEALTHY["services"], "DNS": "Missing"}), "ok"),
        (with_(services={**HEALTHY["services"], "DNS": "Stopped"}), "warn"),
        (with_(services={**HEALTHY["services"], "W32Time": "Stopped"}), "warn"),
        (with_(sysvol_shared=False), "bad"),
        (with_(time_skew_seconds=-75), "warn"),
        (with_(time_skew_seconds=301), "bad"),
        (with_(replication={"failures": 2}), "warn"),
        (with_(replication={"failures": 0, "error": "RPC server unavailable"}), "warn"),
    ],
)
def test_dc_status(dc, expected):
    assert dc_status(dc) == expected


def test_worst():
    assert worst(["ok", "warn", "ok"]) == "warn"
    assert worst(["ok", "bad", "warn"]) == "bad"
    assert worst([]) == "ok"


def test_dc_health_post_adds_status():
    post = OPS["ad_dc_health"].post
    data = post({"items": [HEALTHY, with_(replication={"failures": 1})], "errors": []}, {}, Settings())
    assert [d["status"] for d in data["items"]] == ["ok", "warn"]
    assert data["status"] == "warn"


def test_dc_health_post_marks_unreachable_hosts_bad():
    post = OPS["ad_dc_health"].post
    data = post({"items": [HEALTHY], "errors": [{"host": "dc02", "message": "WinRM cannot complete"}]}, {}, Settings())
    assert data["status"] == "bad"


def test_connection_test_post_flags_privileged_groups_and_warnings():
    post = OPS["ad_connection_test"].post
    data = post(
        {"is_domain_controller": False, "groups": ["CORP\\Domain Admins", "CORP\\Staff"],
         "modules": {"ActiveDirectory": True, "GroupPolicy": False, "WindowsServerBackup": False}},
        {}, Settings(),
    )
    assert data["privileged_memberships"] == ["CORP\\Domain Admins"]
    assert any("not a domain controller" in w for w in data["warnings"])
    assert any("GroupPolicy" in w for w in data["warnings"])


def test_search_args():
    op = OPS["ad_search"]
    assert coerce_args(op, {"query": "bob"}) == {"query": "bob", "kind": "any", "limit": 25}


def test_domain_ops_are_read_only_and_cached_where_expected():
    for name in ("ad_dc_list", "ad_domain_overview", "ad_dc_health", "ad_search", "ad_connection_test"):
        assert OPS[name].tier == "R" and OPS[name].toolset == "ad_domain"
    assert OPS["ad_dc_list"].cache_ttl == 300
    assert OPS["ad_domain_overview"].cache_ttl == 60
