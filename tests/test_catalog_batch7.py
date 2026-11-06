from sysadmin import catalog

BATCH_7 = {"endpoint.pending_reboot", "endpoint.top_processes", "endpoint.stopped_auto_services",
           "endpoint.installed_software", "endpoint.startup_items", "endpoint.recent_errors", "endpoint.hardware",
           "endpoint.battery", "sessions.logged_on", "sessions.user_profiles", "maint.gpupdate",
           "maint.restart_service", "maint.flush_dns", "maint.clear_temp"}


def ids():
    return {o.meta["id"]: o for o in catalog.entries()}


def test_batch_7_present_with_tiers():
    got = ids()
    assert BATCH_7 <= set(got)
    assert {i for i in BATCH_7 if got[i].tier != "R"} == {"maint.gpupdate", "maint.restart_service",
                                                          "maint.flush_dns", "maint.clear_temp"}


def test_restart_service_refuses_winrm_in_script():
    text = (catalog.CATALOG_DIR / "maint" / "restart_service.ps1").read_text()
    for name in ("WinRM", "RpcSs", "LSM", "TermService"):
        assert name in text
    assert "throw" in text and "^[A-Za-z0-9_.-]{1,256}$" in text


def test_clear_temp_never_follows_reparse_points():
    text = (catalog.CATALOG_DIR / "maint" / "clear_temp.ps1").read_text()
    assert "ReparsePoint" in text
