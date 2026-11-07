import re

from sysadmin import catalog
import sysadmin.ops  # noqa: F401  (registers the shipped catalog)

BATCH_11D = {
    "network.routes", "network.arp_cache", "network.tcp_connections", "network.proxy_settings", "network.adapters",
    "network.dns_resolve", "network.traceroute", "network.hosts_file", "network.smb_sessions", "network.smb_open_files",
    "network.mapped_drives", "network.profiles", "network.register_dns", "network.dhcp_renew",
    "dns.forwarders", "dns.server_scavenging", "dns.find_records", "dns.zone_security", "dns.server_events",
    "dns.clear_server_cache",
    "dhcp.scopes", "dhcp.reservations", "dhcp.failover", "dhcp.servers", "dhcp.lease_for_mac",
    "certs.root_store", "certs.ca_health", "certs.template_enrollment",
    "printers.drivers", "printers.ports", "printers.point_and_print", "printers.events", "printers.set_paused",
}
TIERS = {"network.register_dns": "W", "network.dhcp_renew": "H", "dns.clear_server_cache": "W", "printers.set_paused": "W"}
DC = {i for i in BATCH_11D if i.split(".")[0] in ("dns", "dhcp")} | {"certs.ca_health", "certs.template_enrollment"}
CATEGORY = {"network": "Network", "dns": "DNS & DHCP", "dhcp": "DNS & DHCP", "certs": "Certificates", "printers": "Printers"}
DC_FANOUT = {"dns.forwarders", "dns.server_scavenging", "dns.server_events", "dns.clear_server_cache"}
DHCP = {i for i in BATCH_11D if i.startswith("dhcp.")}


def ids():
    return {o.meta["id"]: o for o in catalog.entries()}


def source(entry_id):
    area, name = entry_id.split(".")
    return (catalog.CATALOG_DIR / area / f"{name}.ps1").read_text(encoding="utf-8")


def body(entry_id):
    return source(entry_id).split("#>", 1)[1]


def test_batch_present_with_tiers_targets_and_categories():
    got = ids()
    assert BATCH_11D <= set(got)
    for i in BATCH_11D:
        op = got[i]
        assert op.tier == TIERS.get(i, "R"), i
        assert op.meta["target"] == ("dc" if i in DC else "endpoint"), i
        assert op.meta["category"] == CATEGORY[i.split(".")[0]], i
        assert op.meta["module"].startswith("inbox:"), i
        assert op.preview == (i in TIERS), i
        assert not op.destructive, i


def test_writes_have_preview_that_changes_nothing():
    for i in TIERS:
        text = body(i)
        assert "[switch]$Preview" in text and "if ($Preview) {" in text, i
        preview = text.split("if ($Preview) {", 1)[1].split("return @{", 1)[0]
        for verb in ("Register-DnsClient", "RenewDHCPLease", "Clear-DnsServerCache", "-MethodName $act"):
            assert verb not in preview, (i, verb)
        assert "changes = " in text and "current = $cur" in text, i
    assert ids()["network.dhcp_renew"].meta["preview"] == "plan"


def test_columns_are_emitted_by_the_rows():
    for i in BATCH_11D:
        for col in ids()[i].meta["columns"]:
            if col == "host" and ("Invoke-HermesCatalogFanout" in body(i)):
                continue  # added by the fan-out
            assert re.search(rf"\b{col}\s*=", body(i)), (i, col)


def test_reads_change_nothing():
    forbidden = ("Set-Item", "New-Item", "Remove-Item", "Set-Content", "Add-Content", "Clear-", "Restart-", "Stop-Service",
                 "Start-Service", "Set-Dns", "Set-Dhcp", "Remove-", "Add-Dns", "Invoke-CimMethod", "Register-DnsClient",
                 "Invoke-Expression", "iex ", "Install-Module", "DownloadString", "Invoke-WebRequest")
    for i in BATCH_11D - set(TIERS):
        text = body(i)
        for word in forbidden:
            assert word not in text, (i, word)
    for i in BATCH_11D:
        assert "Invoke-Expression" not in body(i) and "[scriptblock]::Create" not in body(i), i


def test_string_params_validated_with_strict_regex():
    expect = {
        "network.dns_resolve": [r"$Name -cnotmatch '\A(?=.{1,253}\z)", r"$Server -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9.:-]{0,252}\z'", "-cnotcontains $Type"],
        "network.traceroute": [r"$Target -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z'"],
        "network.smb_open_files": [r"""$PathContains -cnotmatch '\A[^\x00-\x1f*?"<>|]{1,200}\z'"""],
        "dns.find_records": [r"$Name -cnotmatch '\A(?=.{1,253}\z)"],
        "dns.clear_server_cache": [r"$Server -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z'"],
        "dhcp.reservations": [r"$Contains -cnotmatch '\A[A-Za-z0-9 ._:-]{1,64}\z'"],
        "dhcp.lease_for_mac": [r"$Mac -cnotmatch '\A[0-9A-Fa-f]{2}(?:[-:]?[0-9A-Fa-f]{2}){5}\z'"],
        "certs.root_store": ["-cnotcontains $Show"],
        "printers.set_paused": [r"""$Printer -cnotmatch '\A[^\\/:*?"<>|\x00-\x1f]{1,256}\z'""", "-cnotcontains $Action"],
    }
    for i, needles in expect.items():
        for n in needles:
            assert n in body(i), (i, n)
    for i in BATCH_11D:
        for p in ids()[i].params:
            if p.type == "string" and p.name not in ("ou",):
                assert p.enum or f"${p.ps} -cnotmatch" in body(i) or f"-cnotcontains ${p.ps}" in body(i), (i, p.name)


def test_user_values_reach_remote_hosts_only_through_argumentlist():
    for i in ("network.dns_resolve", "network.traceroute", "network.smb_open_files", "network.tcp_connections",
              "dhcp.reservations", "dhcp.lease_for_mac", "printers.set_paused", "certs.root_store"):
        assert "Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @(" in body(i) or \
               "Invoke-HermesCatalogFanout -Computers $servers -ArgumentList @(" in body(i), i


def test_dhcp_renew_refuses_servers_and_is_high_risk():
    text = body("network.dhcp_renew")
    assert ids()["network.dhcp_renew"].tier == "H"
    assert "ProductType -ne 1" in text and "Refusing to renew DHCP" in text
    assert "DHCPEnabled = TRUE" in text and "-Kind Workstation" in text
    assert "ReleaseDHCPLease" not in text and "/release" not in text


def test_clear_server_cache_only_targets_a_domain_controller():
    text = body("dns.clear_server_cache")
    assert "Get-ADDomainController -Filter *" in text and "$match.Count -ne 1" in text
    assert "Invoke-HermesCatalogFanout -Computers @($dc)" in text
    assert "Remove-DnsServer" not in text and "ResourceRecord" not in text


def test_no_dns_record_deletion_or_dhcp_writes_anywhere_in_batch():
    for i in BATCH_11D:
        text = body(i)
        assert "Remove-DnsServer" not in text and "Set-DhcpServer" not in text and "Remove-Dhcp" not in text, i


def test_no_secret_values_read():
    # Names, presence or booleans only: no Wi-Fi keys, DHCP failover secret, DNS credential password, private keys.
    assert "SharedSecret" not in body("dhcp.failover")
    servers = body("dhcp.servers")
    assert "dns_credential_set = $cred" in servers and "[bool](\"$((Get-DhcpServerDnsCredential).UserName)\".Trim())" in servers
    assert "Password" not in servers
    for i in ("certs.root_store", "certs.ca_health"):
        assert "PrivateKey" not in body(i) and "HasPrivateKey" not in body(i), i
    assert "UserName" not in body("network.mapped_drives") and "Password" not in body("network.mapped_drives")
    assert "ProxyPass" not in body("network.proxy_settings")


def test_dc_entries_report_errors_and_caps():
    for i in DC:
        text = body(i)
        assert "errors" in text, i
        if i not in TIERS:
            assert "truncated" in text and "Select-Object -First 500" in text, i
    for i in DC_FANOUT:
        text = body(i)
        if i != "dns.clear_server_cache":
            assert "Get-ADDomainController -Filter *" in text and "Invoke-HermesCatalogFanout -Computers $dcs" in text, i
    for i in DHCP:
        text = body(i)
        assert "Get-DhcpServerInDC" in text and "Invoke-HermesCatalogFanout -Computers $servers" in text, i
        assert "NotInstalled: DhcpServer module" in text, i


def test_endpoint_reads_are_bounded_and_have_a_fallback_kind():
    for i in BATCH_11D - DC:
        text = body(i)
        assert re.search(r"-Kind (Workstation|Any|Server)", text), i
        if i not in TIERS:
            assert re.search(r"Select-Object -First \d+|-ge (200|300)|-TotalCount|-MaxEvents", text) or i in (
                "network.proxy_settings", "printers.point_and_print", "network.traceroute"), i


def test_event_entries_treat_no_events_as_empty():
    for i in ("dns.server_events", "printers.events"):
        text = body(i)
        assert "NoMatchingEventsFound" in text and "-MaxEvents $max" in text and "Substring(0, 300)" in text, i


def test_traceroute_hops_are_bounded():
    hops = next(p for p in ids()["network.traceroute"].params if p.name == "Hops")
    assert (hops.minimum, hops.maximum) == (1, 20)
    assert "-Hops $h" in body("network.traceroute")


def test_ca_ping_is_a_bounded_native_call_on_validated_names():
    text = body("certs.ca_health")
    assert "$ErrorActionPreference = 'Continue'; certutil.exe -config $config -ping 2>$null" in text
    assert r"$hostName -cmatch '\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z'" in text


def test_point_and_print_risk_rule():
    text = body("printers.point_and_print")
    assert "RestrictDriverInstallationToAdministrators" in text
    assert "risky = ($restrict -eq 0 -and ($noWarn -eq 1 -or $update -ge 1))" in text


def test_proxy_settings_strip_pac_query_and_proxy_credentials():
    text = body("network.proxy_settings")
    assert r"$v -replace '[?#].*\z', ''" in text and "Get-Clean \"$($is.AutoConfigURL)\" $true" in text
    assert "Get-Clean \"$($is.ProxyServer)\" $false" in text and r"(?<=://)[^/@\s;]*@" in text


def test_dns_resolve_only_asks_dcs_or_configured_servers():
    text = body("network.dns_resolve")
    assert "Get-ADDomainController -Filter *" in text and "$isDc = $true" in text
    assert "Get-DnsClientServerAddress" in text and "$configured -notcontains $srv" in text
    assert "refused: $srv is neither a domain controller" in text
    assert text.index("$configured -notcontains $srv") < text.index("$splat.Server = $srv")


def test_dns_cache_and_register_dns_report_real_state():
    cache = body("dns.clear_server_cache")
    assert "Show-DnsServerCache" in cache and "$before = Get-CacheCount" in cache and "after = (Get-CacheCount)" in cache
    assert "cached answers present" not in cache
    reg = body("network.register_dns")
    assert "$before = Get-OwnA" in reg and "after = (Get-OwnA)" in reg and "-DnsOnly" in reg
    assert "registration not requested" not in reg
