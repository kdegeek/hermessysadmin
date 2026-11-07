import re

from sysadmin import catalog
import sysadmin.ops  # noqa: F401  (registers the shipped catalog)

READS = {
    "endpoint.os_version", "endpoint.resource_pressure", "endpoint.physical_disks", "endpoint.unexpected_shutdowns",
    "endpoint.app_crashes", "endpoint.reliability", "endpoint.problem_devices", "endpoint.drivers",
    "endpoint.scheduled_tasks", "endpoint.service_accounts", "endpoint.time_sync", "endpoint.page_file",
    "endpoint.power_settings", "endpoint.largest_folders", "endpoint.activation", "endpoint.windows_features",
    "endpoint.boot_performance", "endpoint.component_health",
}
WRITES = {"maint.time_resync": "W", "maint.set_service_startup": "W", "maint.stop_process": "H",
          "maint.empty_recycle_bin": "H", "maint.clear_wu_cache": "H", "maint.remove_stale_profiles": "H"}
DESTRUCTIVE = {"maint.empty_recycle_bin", "maint.remove_stale_profiles"}
BATCH = READS | set(WRITES)


def ids():
    return {o.meta["id"]: o for o in catalog.entries()}


def source(entry_id):
    area, name = entry_id.split(".")
    return (catalog.CATALOG_DIR / area / f"{name}.ps1").read_text(encoding="utf-8")


def body(entry_id):
    return source(entry_id).split("#>", 1)[1]


def test_batch_present_with_tiers_targets_and_categories():
    got = ids()
    assert len(BATCH) == 24 and BATCH <= set(got)
    for i in READS:
        assert got[i].tier == "R" and not got[i].preview, i
        assert got[i].meta["category"] == "Endpoint health", i
    for i, tier in WRITES.items():
        assert got[i].tier == tier and got[i].preview and got[i].meta["preview"] == "plan", i
        assert got[i].meta["category"] == "Maintenance", i
        assert "[switch]$Preview" in source(i) and "if ($Preview)" in source(i), i
        assert got[i].destructive == (i in DESTRUCTIVE), i
    for i in BATCH:
        assert got[i].meta["target"] == "endpoint", i
        assert got[i].meta["module"].startswith("inbox:"), i


def test_header_columns_are_emitted_by_the_rows():
    for i in BATCH:
        text = body(i)
        for col in ids()[i].meta["columns"]:
            if col == "host":
                continue  # added by the fan-out
            if i == "endpoint.power_settings" and col.endswith("_min"):
                assert re.search(rf"\b{col}\s*=", text) and '$row["$($k)_$($src.ToLowerInvariant())_min"]' in text
                continue
            assert re.search(rf"\b{col}\s*=", text), (i, col)


def test_every_entry_fans_out_and_uses_51_syntax():
    for i in BATCH:
        text = body(i)
        assert "Invoke-Op {" in text and "Invoke-HermesCatalogFanout -Computers $targets" in text, i
        assert "Get-HermesTargets -Computers $Computers -Ou $Ou -Kind" in text, i
        for bad in ("??", "-Parallel", "Join-String", "-AsHashtable", "Invoke-Expression", "iex ", "Install-Module",
                    "DownloadString", "Invoke-WebRequest"):
            assert bad not in text, (i, bad)
        assert not re.search(r"\)\s*(&&|\|\|)\s", text), i


def test_reads_change_nothing():
    for i in READS:
        text = body(i)
        for verb in ("Set-", "Remove-", "Stop-", "Start-Service", "Restart-", "Rename-", "New-Item", "Clear-",
                     "Disable-", "Enable-", "Register-", "Unregister-", "/resync", "/ScanHealth", "/RestoreHealth",
                     "/scannow", "Repair-"):
            assert verb not in text, (i, verb)
    assert "/CheckHealth" in source("endpoint.component_health")


def test_no_secrets_are_read():
    act = source("endpoint.activation")
    select = re.search(r'SELECT (.*?) FROM SoftwareLicensingProduct', act).group(1)
    assert "PartialProductKey" not in select and "ProductKey" not in select
    assert "OA3xOriginalProductKey" not in act and "SoftwareLicensingService" not in act
    tasks = source("endpoint.scheduled_tasks")
    assert ".Execute" in tasks and ".Arguments" not in tasks and "Principal.UserId" in tasks
    svc = source("endpoint.service_accounts")
    assert "StartName" in svc and "Password" not in body("endpoint.service_accounts")


def test_event_reads_treat_no_events_as_empty_and_are_bounded():
    for i in ("endpoint.unexpected_shutdowns", "endpoint.app_crashes", "endpoint.boot_performance"):
        text = source(i)
        assert "NoMatchingEventsFound" in text and "-MaxEvents" in text and "FilterHashtable" in text, i
    assert "NoMatchingLogsFound" in source("endpoint.boot_performance")
    shut = source("endpoint.unexpected_shutdowns")
    assert "Id = 41, 6008, 1001" in shut and "Microsoft-Windows-Kernel-Power" in shut
    assert "Id = 1000, 1002" in source("endpoint.app_crashes")


def test_string_params_are_allow_listed():
    assert r"-cnotmatch '\A[A-Za-z0-9 ._()&+-]{0,100}\z'" in source("endpoint.drivers")
    assert r"-cnotmatch '\A[A-Za-z0-9 ._-]{0,100}\z'" in source("endpoint.windows_features")
    folders = source("endpoint.largest_folders")
    assert r"-cnotmatch '\A[A-Za-z]:\\[^:*?<>|" in folders and "'..'" in folders
    assert r"-cnotmatch '\A[A-Za-z0-9_.-]{1,256}\z'" in source("maint.set_service_startup")
    assert r"-cnotmatch '\A[A-Za-z0-9][A-Za-z0-9 ._-]{0,99}\z'" in source("maint.stop_process")
    assert r"-cnotmatch '\A([A-Za-z0-9][A-Za-z0-9._-]{0,14}\\)?[A-Za-z0-9 ._$@-]{1,104}\z'" in source("maint.remove_stale_profiles")


def test_largest_folders_is_bounded_and_skips_reparse_points():
    folders = ids()["endpoint.largest_folders"]
    depth = next(p for p in folders.params if p.name == "Depth")
    top = next(p for p in folders.params if p.name == "Top")
    assert (depth.minimum, depth.maximum, top.maximum) == (1, 3, 100)
    text = source("endpoint.largest_folders")
    assert "TotalSeconds -ge 45" in text and "ReparsePoint" in text and "complete = $complete" in text


def test_set_service_startup_refuses_critical_services_and_drivers():
    op = ids()["maint.set_service_startup"]
    st = next(p for p in op.params if p.name == "StartupType")
    assert st.enum == ("Automatic", "Manual", "Disabled") and st.required
    assert op.meta["id"] and op.escalate is not None
    text = source("maint.set_service_startup")
    assert "escalate_when:\n  StartupType: [Disabled]" in text
    for svc in ("'winrm'", "'rpcss'", "'netlogon'", "'ntds'", "'kdc'", "'dns'", "'mpssvc'", "'windefend'", "'termservice'",
                "'lanmanworkstation'", "'winmgmt'", "'samss'", "'eventlog'", "'dcomlaunch'", "'bfe'", "'dfsr'"):
        assert svc in text, svc
    assert "PolicyBlocked:" in text and "Win32_Service -Filter" in text and "drivers are not supported" in text
    assert "Stop-Service" not in text and "Start-Service" not in text


def test_set_service_startup_disabled_escalates():
    op = ids()["maint.set_service_startup"]

    class Facts:
        def domain_controllers(self):
            return ["dc1.example.com"]

    base = {"computers": ["ws1.example.com"], "Name": "Spooler"}
    assert not op.escalate({**base, "StartupType": "Manual"}, None, Facts())
    assert op.escalate({**base, "StartupType": "Disabled"}, None, Facts())


def test_stop_process_refuses_core_processes():
    text = source("maint.stop_process")
    for p in ("'csrss'", "'lsass'", "'winlogon'", "'services'", "'smss'", "'wininit'", "'svchost'", "'explorer'",
              "'wsmprovhost'", "'msmpeng'", "'system'", "'dwm'", "'conhost'"):
        assert p in text, p
    assert r"-replace '(?i)\.exe\z'" in text and "$_.Id -ne $PID" in text and "PolicyBlocked:" in text
    assert "Stop-Process -Id $x.Id -Force" in text


def test_empty_recycle_bin_never_follows_links_and_is_bounded():
    text = source("maint.empty_recycle_bin")
    assert "[IO.Directory]::Delete($c.FullName, $false)" in text and "[IO.Directory]::Delete($item.FullName, $false)" in text
    assert "-Recurse" not in body("maint.empty_recycle_bin")
    assert "TotalSeconds -ge 45" in text and r"'\AS-1-[0-9-]+\z'" in text and "DriveType = 3" in text
    assert "-ArgumentList @($OlderThanDays, $false)" in text and "-ArgumentList @($OlderThanDays, $true)" in text


def test_clear_wu_cache_renames_restarts_and_skips_busy_hosts():
    text = source("maint.clear_wu_cache")
    assert "Rename-Item -LiteralPath $dl -NewName $newName" in text and "Remove-Item" not in text
    assert "} finally {" in text and "Start-Service -Name $s" in text and "$wasRunning" in text
    assert "HermesSysadmin-WUInstall" in text and "TiWorker" in text and "IsBusy" in text
    assert "ReparsePoint" in text and "DataStore" not in body("maint.clear_wu_cache")
    assert "-ArgumentList @($false)" in text and "-ArgumentList @($true)" in text


def test_remove_stale_profiles_guards():
    op = ids()["maint.remove_stale_profiles"]
    days = next(p for p in op.params if p.name == "MinDaysUnused")
    mx = next(p for p in op.params if p.name == "Max")
    assert days.minimum == 30 and days.default == 90 and mx.maximum == 200
    text = source("maint.remove_stale_profiles")
    assert "if ($MinDaysUnused -lt 30) { throw" in text
    assert "$p.Special -or $p.Loaded -or -not $p.LocalPath -or -not $p.LastUseTime" in text
    assert "$sid -eq $me -or $sid -match '-500\\z'" in text and "ProfilesDirectory" in text
    assert "$keepSet -contains" in text and "Remove-CimInstance -InputObject $c.p" in text
    assert "Remove-Item" not in text and "-ArgumentList @($MinDaysUnused, $keep, $Max, $false)" in text


def test_time_resync_only_resyncs():
    text = source("maint.time_resync")
    assert "w32tm.exe /resync 2>&1" in text and "/config" not in text and "/register" not in text
    assert "Set-ItemProperty" not in text and "-ArgumentList @($false)" in text
