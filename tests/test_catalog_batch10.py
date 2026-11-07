import re

from sysadmin import catalog
import sysadmin.ops  # noqa: F401  (registers the shipped catalog)

BATCH_10 = {
    "network.ip_config", "network.dns_client", "network.listening_ports", "network.test_port", "network.smb_shares",
    "network.wifi_profiles", "printers.list", "printers.queue", "printers.clear_queue", "printers.restart_spooler",
    "certs.expiring", "certs.adcs_templates", "events.failed_logons", "events.lockouts", "events.rdp_logons",
    "events.service_installs", "events.search", "files.ntfs_access", "files.ntfs_orphaned_sids", "files.ntfs_inheritance",
}
WRITES = {"printers.clear_queue", "printers.restart_spooler"}
DC = {"certs.adcs_templates", "events.failed_logons", "events.lockouts", "files.ntfs_access", "files.ntfs_orphaned_sids",
      "files.ntfs_inheritance"}
FILES = {i for i in BATCH_10 if i.startswith("files.")}


def ids():
    return {o.meta["id"]: o for o in catalog.entries()}


def source(entry_id):
    area, name = entry_id.split(".")
    return (catalog.CATALOG_DIR / area / f"{name}.ps1").read_text()


def test_batch_10_present_with_tiers_and_targets():
    got = ids()
    assert len(BATCH_10) == 20 and BATCH_10 <= set(got)
    for i in BATCH_10:
        assert got[i].tier == ("W" if i in WRITES else "R"), i
        assert got[i].meta["target"] == ("dc" if i in DC else "endpoint"), i
    assert "files.ntfs_effective_access" not in got


def test_catalog_size_and_categories():
    ops = catalog.entries()
    assert len(ops) >= 95
    assert {o.meta["category"] for o in ops} == set(catalog.CATEGORIES)


def test_no_gallery_modules_ship_and_nothing_reads_wifi_keys():
    for op in catalog.entries():
        assert not str(op.meta["module"]).startswith("gallery:"), op.name
    for path in catalog.CATALOG_DIR.rglob("*"):
        if path.is_file():
            assert "key=clear" not in path.read_text(encoding="utf-8").lower(), path


def test_header_columns_are_emitted_by_the_rows():
    for i in BATCH_10:
        body = source(i).split("#>", 1)[1]
        for col in ids()[i].meta["columns"]:
            if col == "host" and i not in {"certs.adcs_templates", "events.failed_logons", "events.lockouts"}:
                continue  # added by the fan-out
            assert re.search(rf"\b{col}\s*=", body), (i, col)


def test_file_entries_run_in_box_on_the_server_with_validated_inputs():
    for i in FILES:
        text = source(i)
        assert "Invoke-HermesCatalogFanout -Computers @($Server)" in text and "Use-HermesModule" not in text, i
        assert r"-cnotmatch '\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z'" in text and r"\A[A-Za-z]:\\[^:*?<>|" in text and "'..'" in text, i
        assert "Get-Acl -LiteralPath" in text and "truncated" in text and "Select-Object -First 500" in text, i
        assert ids()[i].meta["module"].startswith("inbox:"), i
    for i in ("files.ntfs_orphaned_sids", "files.ntfs_inheritance"):
        depth = next(p for p in ids()[i].params if p.name == "Depth")
        assert depth.maximum == 5 and depth.default == 2, i
        text = source(i)
        assert "ReparsePoint" in text and "Path is a reparse point" in text and "-lt 2000" in text, i
        assert "catch { $skipped++" in text and "skipped = $skipped" in text and "folders_visited" in text, i
    assert "catch [System.Security.Principal.IdentityNotMappedException]" in source("files.ntfs_orphaned_sids")
    assert "unresolved" in source("files.ntfs_orphaned_sids")


def test_event_dc_entries_fan_out_to_every_dc_without_computername():
    for i in ("events.failed_logons", "events.lockouts"):
        text = source(i)
        assert "Get-ADDomainController -Filter *" in text and "Invoke-HermesCatalogFanout -Computers $dcs" in text, i
        assert "FilterHashtable" in text and "-ComputerName" not in text and "PDC" not in text.split("#>", 1)[1], i
    assert "$seen" in source("events.lockouts")


def test_printers_writes_validate_and_stop_on_errors():
    clear = source("printers.clear_queue")
    assert r"""-cnotmatch '\A[^\\/:*?"<>|\x00-\x1f]{1,256}\z'""" in clear
    assert "total = $all.Count" in clear and "totals = $totals" in clear
    assert ids()["printers.clear_queue"].meta["preview"] == "plan"
    for i in WRITES:
        assert "$ErrorActionPreference = 'Stop'" in source(i) and "[switch]$Preview" in source(i), i


def test_network_inputs_and_wifi_native_call():
    port = ids()["network.test_port"]
    p = next(x for x in port.params if x.name == "Port")
    assert (p.minimum, p.maximum) == (1, 65535)
    assert r"-cnotmatch '\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z'" in source("network.test_port")
    assert "ping_ms" in port.meta["columns"] and "latency_ms" not in source("network.test_port")
    wifi = source("network.wifi_profiles")
    assert "$ErrorActionPreference = 'Continue'; netsh wlan show profiles 2>$null" in wifi


def test_endpoint_fallback_kind_and_row_caps():
    for i in BATCH_10 - DC:
        text = source(i)
        assert "-Kind Workstation" in text or "-Kind Any" in text, i
    for i in DC:
        assert "errors" in source(i) and "truncated" in source(i), i
    assert "Substring(0, 300)" in source("events.search")


def test_failed_logons_reports_capped_dcs():
    text = source("events.failed_logons")
    assert "capped_dcs" in text and "-ge 5000" in text
