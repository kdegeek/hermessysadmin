import re

from sysadmin import catalog
import sysadmin.ops  # noqa: F401  (registers the shipped catalog)

BATCH_9B = {"gpo.unlinked", "gpo.empty", "gpo.version_mismatch", "gpo.permissions", "gpo.broken",
            "gpo.permission_analysis", "gpo.link_summary", "gpo.owners", "gpo.netlogon_files", "gpo.sysvol_dfsr",
            "gpo.gpp_password_exposure", "dns.zones", "dns.stale_records", "dhcp.scope_utilization",
            "dhcp.leases_for_host"}


def ids():
    return {o.meta["id"]: o for o in catalog.entries()}


def source(entry_id):
    area, name = entry_id.split(".")
    return (catalog.CATALOG_DIR / area / f"{name}.ps1").read_text()


def test_batch_9b_present_read_only_dc():
    got = ids()
    assert len(BATCH_9B) == 15 and BATCH_9B <= set(got)
    for i in BATCH_9B:
        assert got[i].tier == "R" and got[i].meta["target"] == "dc", i


def test_every_gallery_entry_uses_the_module_loader():
    for i in BATCH_9B:
        if str(ids()[i].meta["module"]).startswith("gallery:"):
            assert "Use-HermesModule" in source(i), i


def test_rows_are_capped_and_flag_truncation():
    for i in BATCH_9B:
        text = source(i)
        assert "Select-Object -First 500" in text and "truncated" in text, i


def test_header_columns_are_emitted_by_the_rows():
    for i in BATCH_9B:
        body = source(i).split("#>", 1)[1]
        for col in ids()[i].meta["columns"]:
            if col == "host" and i == "gpo.sysvol_dfsr":  # added by the fan-out
                continue
            assert re.search(rf"\b{col}\s*=", body), (i, col)


def test_errors_use_host_and_message_shape():
    for i in BATCH_9B:
        text = source(i)
        if "errors" in text and "@{ host =" in text:
            assert re.search(r"@\{ host = [^;]+; message =", text), i


def test_gpp_password_exposure_never_outputs_a_match_value():
    text = source("gpo.gpp_password_exposure")
    assert ".Matches.Count" in text and "cpassword=\"[^\"]+" in text
    assert "$_.Value" not in text and ".Matches[" not in text
    assert "cpassword =" not in text
    assert "-LiteralPath" in text and "Preferences" in text


def test_dns_and_dhcp_validate_inputs_and_report_missing_modules():
    assert "^[A-Za-z0-9.-]{1,253}$" in source("dns.stale_records")
    assert "^[A-Za-z0-9.-]{1,64}$" in source("dhcp.leases_for_host")
    for i in ("dns.zones", "dns.stale_records", "dhcp.scope_utilization", "dhcp.leases_for_host"):
        assert "NotInstalled: " in source(i) and "module not present on the jump host" in source(i), i


def test_dhcp_runs_locally_on_each_server_without_computername():
    for i in ("dhcp.scope_utilization", "dhcp.leases_for_host"):
        text = source(i)
        assert "Get-DhcpServerInDC" in text and "Invoke-HermesCatalogFanout" in text
        assert "-ComputerName" not in text, i
    assert "-ComputerName" not in source("dns.zones") and "-ComputerName" not in source("dns.stale_records")


def test_sysvol_dfsr_fans_out_and_no_cross_server_cim():
    text = source("gpo.sysvol_dfsr")
    assert "Invoke-HermesCatalogFanout" in text and "root\\microsoftdfs" in text and "-ComputerName" not in text
