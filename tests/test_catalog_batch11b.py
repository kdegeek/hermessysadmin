import re

from sysadmin import catalog
import sysadmin.ops  # noqa: F401  (registers the shipped catalog)

READS = {
    "security.smb_signing", "security.name_resolution", "security.lsa_protection", "security.ntlm_settings",
    "security.uac_settings", "security.powershell_logging", "security.audit_policy", "security.local_users",
    "security.autorun_policy", "security.logon_screen_policy", "security.firewall_open_inbound",
    "security.share_open_write", "security.unquoted_service_paths", "security.defender_exclusions",
    "security.defender_asr", "security.schannel_ciphers", "remote.rdp_listener", "remote.winrm_listeners",
    "remote.remote_admin_services", "remote.rdp_session_limits",
}
WRITES = {
    "security.defender_quick_scan", "security.defender_update_signatures", "security.disable_smb1_server",
    "security.disable_llmnr", "security.enable_firewall_profiles",
}
BATCH = READS | WRITES


def ids():
    return {o.meta["id"]: o for o in catalog.entries()}


def source(entry_id):
    area, name = entry_id.split(".")
    return (catalog.CATALOG_DIR / area / f"{name}.ps1").read_text(encoding="utf-8")


def body(entry_id):
    return source(entry_id).split("#>", 1)[1]


def test_batch_present_with_tiers_targets_and_categories():
    got = ids()
    assert len(BATCH) == 25 and BATCH <= set(got)
    for i in BATCH:
        op = got[i]
        assert op.tier == ("W" if i in WRITES else "R"), i
        assert op.meta["target"] == "endpoint", i
        assert op.meta["category"] == ("Remote access" if i.startswith("remote.") else "Security posture"), i
        assert op.meta["module"].startswith("inbox:"), i
        assert op.preview == (i in WRITES) and op.meta["preview"] == ("plan" if i in WRITES else "none"), i
        assert not op.destructive, i
        assert "Invoke-Op {" in source(i) and "Invoke-HermesCatalogFanout" in source(i), i


def test_header_columns_are_emitted_by_the_rows():
    for i in BATCH:
        for col in ids()[i].meta["columns"]:
            if col == "host":
                continue  # added by the fan-out
            assert re.search(rf"\b{col}\s*=", body(i)), (i, col)


def test_no_unsafe_constructs_or_ps7_syntax():
    banned = ("Invoke-Expression", "iex ", "Install-Module", "DownloadString", "Invoke-WebRequest", "Use-HermesModule",
              "Set-MpPreference", "Add-MpPreference", "Remove-MpPreference", "ConvertFrom-SecureString", "-Parallel",
              "Join-String", "-AsHashtable", " ?? ", "&&", "||")
    for i in BATCH:
        text = body(i)
        for b in banned:
            assert b not in text, (i, b)


def test_reads_change_nothing():
    writers = re.compile(r"\b(Set|New|Remove|Clear|Rename|Enable|Disable|Start|Stop|Restart|Update|Register)-(?!Object\b)"
                         r"|Invoke-CimMethod|\.SetValue\(|\.DeleteValue\(|\.CreateSubKey\(|OpenSubKey\([^)]*\$true")
    for i in READS:
        assert not writers.search(body(i)), i
        assert "[switch]$Preview" not in source(i), i
    assert "OpenSubKey($Path, $false)" in body("security.schannel_ciphers")
    assert "auditpol.exe /get /category:* /r" in body("security.audit_policy")
    assert "/set" not in body("security.audit_policy") and "/clear" not in body("security.audit_policy")


def test_reads_never_return_secrets():
    users = body("security.local_users")
    assert "Get-LocalUser" in users and "DomainRole -ge 4" in users
    for prop in ("PasswordLastSet", "PasswordExpires", "PasswordRequired"):
        assert prop in users
    assert not re.search(r"\$u\.Password\b|\bPassword\s*=", users)
    notice = body("security.logon_screen_policy")
    assert "legal_notice            = [bool](" in notice  # presence only, never the text
    rdp = body("remote.rdp_listener")
    assert "PrivateKey" not in rdp and "Export" not in rdp and r"-cmatch '\A[0-9A-F]{40}\z'" in rdp
    winrm = body("remote.winrm_listeners")
    assert "Substring(0, 300)" in winrm and "Password" not in winrm
    for i in BATCH:
        assert "key=clear" not in body(i).lower() and "cpassword" not in body(i).lower(), i


def test_row_caps():
    for i in ("security.firewall_open_inbound", "security.share_open_write", "security.unquoted_service_paths",
              "security.defender_exclusions", "security.local_users"):
        assert "200" in body(i), i
    audit = body("security.audit_policy")
    assert "Select-Object -First 500" in audit and "truncated" in audit


def test_writes_preview_reads_real_state_and_changes_nothing():
    for i in WRITES:
        text = body(i)
        assert "[switch]$Preview" in source(i), i
        assert "if ($Preview) {" in text and "-ArgumentList @($false) -Script $work" in text, i
        assert "-ArgumentList @($true) -Script $work" in text, i
        assert "if (-not $apply)" in text, i
        assert "summary =" in text and "changes =" in text and "current =" in text, i
        # the only change sits after the preview gate inside the shared scriptblock
        gate = text.index("if (-not $apply)")
        for verb in ("Set-SmbServerConfiguration", "Set-ItemProperty", "Set-NetFirewallProfile", "Invoke-CimMethod"):
            if verb in text:
                assert text.index(verb) > gate, (i, verb)


def test_defender_actions_use_fixed_command_lines():
    for i, arg in (("security.defender_quick_scan", "-Scan -ScanType 1"), ("security.defender_update_signatures", "-SignatureUpdate")):
        text = body(i)
        assert f'CommandLine = "`"$exe`" {arg}"' in text, i
        assert "Join-Path $env:ProgramFiles 'Windows Defender\\MpCmdRun.exe'" in text, i
        assert "AntivirusEnabled" in text and "skipped:" in text, i
        assert {p.name for p in ids()[i].params} == {"computers", "ou"}, i


def test_smb1_disable_refuses_dcs_and_live_smb1_clients():
    text = body("security.disable_smb1_server")
    assert "DomainRole" in text and "$role -ge 4" in text and "refused: domain controller" in text
    assert "Dialect" in text and "'1.*'" in text and "refused: $($s1.Count) SMB1 session(s)" in text
    assert "-EnableSMB1Protocol $false" in text and "-EnableSMB1Protocol $true" not in text
    assert "Disable-WindowsOptionalFeature" not in text


def test_firewall_write_only_turns_profiles_on_and_protects_management():
    text = body("security.enable_firewall_profiles")
    assert "Set-NetFirewallProfile -Profile $toOn -Enabled True" in text
    assert "-Enabled False" not in text and "Disable-NetFirewallRule" not in text and "Set-NetFirewallRule" not in text
    assert "-LocalPort 5985, 5986" in text and "fDenyTSConnections" in text and "PortNumber" in text
    assert "refused:" in text and "AllowInboundRules" in text and "'Block'" in text
    assert "PolicyStore RSOP" in text and "Get-NetConnectionProfile" in text
    # problems short-circuit before the change
    assert text.index("if ($problems.Count -gt 0)") < text.index("Set-NetFirewallProfile")


def test_llmnr_write_only_disables():
    text = body("security.disable_llmnr")
    assert r"HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" in text
    assert "-Name EnableMulticast -Value 0 -Type DWord" in text
    assert "-Value 1" not in text and "Remove-ItemProperty" not in text


def test_boolean_params_have_safe_defaults():
    got = ids()
    for i, name in (("security.audit_policy", "NotAuditedOnly"), ("security.firewall_open_inbound", "IncludeBuiltIn")):
        p = next(x for x in got[i].params if x.name == name)
        assert p.type == "boolean" and p.default is False, i
    for i in BATCH:
        assert not any(p.type == "string" for p in got[i].params if p.name not in ("ou",)), i


def test_fleet_writes_escalate():
    for i in WRITES:
        assert ids()[i].escalate is not None, i
