"""Live tests against a real domain. Read-only unless SYSADMIN_LIVE_WRITE=1.

Write tests only create/modify objects named zz-hermes-test-* inside SYSADMIN_TEST_OU and
always clean up, even on failure.
"""

import json
import os
import uuid

import pytest

from sysadmin import ops  # noqa: F401
from sysadmin.config import settings_from
from sysadmin.runtime import build_service

pytestmark = [
    pytest.mark.live,
    pytest.mark.skipif(os.environ.get("SYSADMIN_LIVE") != "1", reason="set SYSADMIN_LIVE=1 to run live tests"),
]
WRITE = os.environ.get("SYSADMIN_LIVE_WRITE") == "1"
TEST_OU = os.environ.get("SYSADMIN_TEST_OU", "")
SERVER = os.environ.get("SYSADMIN_TEST_SERVER", "")


@pytest.fixture(scope="module")
def svc():
    raw = {
        "host": os.environ.get("SYSADMIN_HOST", ""),
        "username": os.environ.get("SYSADMIN_USER", ""),
        "port": os.environ.get("SYSADMIN_PORT", "5986"),
        "use_https": os.environ.get("SYSADMIN_HTTPS", "true"),
        "verify_tls": os.environ.get("SYSADMIN_VERIFY_TLS", "true"),
        "mode": "strict",
    }
    service = build_service(settings_from(raw, os.environ.get("SYSADMIN_WINRM_PASSWORD", "")))
    yield service
    service.runner.close()


def ok(result):
    assert result["ok"], result.get("error")
    return result["data"]


def call(svc, name, args=None, approved=False):
    return svc.call(name, args or {}, actor="agent", session="live-tests", approved=approved)


@pytest.mark.parametrize(
    "name, args",
    [
        ("ad_connection_test", {}),
        ("ad_dc_list", {}),
        ("ad_domain_overview", {}),
        ("ad_dc_health", {}),
        ("ad_search", {"query": "Domain Admins"}),
        ("ad_user_list", {"status": "locked", "limit": 5}),
        ("ad_group_get", {"identity": "Domain Admins"}),
        ("ad_recycle_bin_list", {"limit": 5}),
        ("gpo_list", {}),
        ("gpo_health", {}),
        ("gpo_report", {"identity": "Default Domain Policy"}),
        ("gpo_backups", {}),
        ("rdp_sessions", {}),
        ("rdp_host_status", {}),
        ("backup_status", {}),
        ("sysadmin_audit_log", {"limit": 5}),
    ],
)
def test_reads(svc, name, args):
    ok(call(svc, name, args))


def test_domain_controllers_are_healthy_enough(svc):
    data = ok(call(svc, "ad_dc_health"))
    assert data["items"], "no DCs returned"
    assert data["status"] in ("ok", "warn"), data


@pytest.mark.skipif(not SERVER, reason="set SYSADMIN_TEST_SERVER for host-specific reads")
@pytest.mark.parametrize("name", ["backup_versions", "backup_jobs", "rdp_connect_file"])
def test_host_reads(svc, name):
    ok(call(svc, name, {"host": SERVER}))


def test_writes_are_refused_without_approval(svc):
    out = call(svc, "ad_user_unlock", {"identity": "zz-hermes-test-nobody"})
    assert out["error"]["type"] == "ApprovalRequired"


def test_protected_objects_are_blocked_live(svc):
    out = call(svc, "ad_user_disable", {"identity": "krbtgt"}, approved=True)
    assert out["error"]["type"] == "PolicyBlocked"


@pytest.mark.skipif(not (WRITE and TEST_OU), reason="set SYSADMIN_LIVE_WRITE=1 and SYSADMIN_TEST_OU")
def test_user_lifecycle(svc):
    sam = f"zz-hermes-test-{uuid.uuid4().hex[:6]}"
    try:
        created = ok(call(svc, "ad_user_create", {"sam": sam, "given_name": "Hermes", "surname": "Test", "ou": TEST_OU}, approved=True))
        assert created.get("password"), "generated password must be returned once"
        ok(call(svc, "ad_user_disable", {"identity": sam, "note": "live test"}, approved=True))
        assert ok(call(svc, "ad_user_get", {"identity": sam}))["enabled"] is False
        ok(call(svc, "ad_user_enable", {"identity": sam}, approved=True))
        reset = ok(call(svc, "ad_user_reset_password", {"identity": sam}, approved=True))
        logged = json.dumps(svc.audit.query(limit=20))
        assert created["password"] not in logged and reset["password"] not in logged
        preview = ok(svc.preview("ad_user_delete", {"identity": sam}))
        assert preview.get("summary")
    finally:
        call(svc, "ad_user_delete", {"identity": sam}, approved=True)


@pytest.mark.skipif(not (WRITE and TEST_OU), reason="set SYSADMIN_LIVE_WRITE=1 and SYSADMIN_TEST_OU")
def test_gpo_lifecycle(svc):
    name = f"zz-hermes-test-gpo-{uuid.uuid4().hex[:6]}"
    try:
        ok(call(svc, "gpo_create", {"name": name, "comment": "live test"}, approved=True))
        backup = ok(call(svc, "gpo_backup", {"identity": name}, approved=True))
        ok(call(svc, "gpo_link", {"identity": name, "target": TEST_OU}, approved=True))
        linked = ok(call(svc, "gpo_get", {"identity": name}))
        assert any(link["target"].lower() == TEST_OU.lower() for link in linked["links"])
        ok(call(svc, "gpo_set_link", {"identity": name, "target": TEST_OU, "enabled": False}, approved=True))
        ok(call(svc, "gpo_unlink", {"identity": name, "target": TEST_OU}, approved=True))
        ok(svc.preview("gpo_restore", {"identity": name, "backup_id": backup["backup_id"]}))
    finally:
        call(svc, "gpo_delete", {"identity": name}, approved=True)
