import re

from sysadmin import catalog
import sysadmin.ops  # noqa: F401  (registers the shipped catalog)

BATCH_11C = {
    "ad.privileged_members", "ad.sid_history", "ad.must_change_password", "ad.expiring_accounts", "ad.disabled_in_groups",
    "ad.recently_created", "ad.computer_os", "ad.forest_settings", "ad.ou_tree", "ad.protected_users",
    "ad.managed_service_accounts", "ad.constrained_delegation", "ad.sites_subnets", "ad.no_client_site",
    "ad.kerberos_encryption", "ad.group_nesting", "ad.stale_machine_passwords", "ad.fgpp_applies_to",
    "ad.protect_ous", "ad.move_computer", "ad.disable_stale_computers",
    "sessions.user_groups", "sessions.find_user", "sessions.user_last_logon",
}
TIERS = {"ad.protect_ous": "W", "ad.move_computer": "W", "ad.disable_stale_computers": "H"}
ENDPOINT = {"sessions.find_user"}
UNCAPPED = {"ad.forest_settings", "sessions.user_last_logon"}  # a handful of rows: one per setting / per DC
WRITES = set(TIERS)
SECRET_ATTRS = ("ms-Mcs-AdmPwd", "msLAPS-Password", "msLAPS-EncryptedPassword", "unicodePwd", "dBCSPwd", "ntPwdHistory",
                "lmPwdHistory", "supplementalCredentials", "msFVE-RecoveryPassword", "msKds-RootKeyData", "Get-KdsRootKey",
                "Get-LapsADPassword", "Get-AdmPwdPassword", "cpassword", "DSInternals", "Install-Module", "Invoke-Expression")
IDENTITY_RE = r"-cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._@-]{0,255}\z'"
COMPUTER_RE = r"-cnotmatch '\A[A-Za-z0-9][A-Za-z0-9_-]{0,14}\z'"


def ids():
    return {o.meta["id"]: o for o in catalog.entries()}


def source(entry_id):
    area, name = entry_id.split(".")
    return (catalog.CATALOG_DIR / area / f"{name}.ps1").read_text(encoding="utf-8")


def body(entry_id):
    return source(entry_id).split("#>", 1)[1]


def test_batch_11c_present_with_tiers_targets_and_categories():
    got = ids()
    assert BATCH_11C <= set(got)
    for i in BATCH_11C:
        assert got[i].tier == TIERS.get(i, "R"), i
        assert got[i].meta["target"] == ("endpoint" if i in ENDPOINT else "dc"), i
        assert got[i].meta["category"] == ("Users & sessions" if i.startswith("sessions.") else "AD hygiene"), i
        assert got[i].meta["module"].startswith("inbox:"), i
        assert not got[i].destructive, i


def test_typed_tools_are_not_duplicated():
    got = ids()
    # DC inventory, locked-out users and user enable/disable/move are typed tools (ad_dc_list, ad_user_list, ad_user_*).
    for dup in ("ad.dc_inventory", "ad.locked_out", "ad.move_user", "ad.disable_user", "ad.unlock_user"):
        assert dup not in got


def test_header_columns_are_emitted_by_the_rows():
    got = ids()
    for i in BATCH_11C:
        for col in got[i].meta["columns"]:
            if col == "host":
                continue  # added by the fan-out
            assert re.search(rf"\b{col}\s*=", body(i)), (i, col)


def test_reads_cap_rows_and_report_truncation():
    for i in BATCH_11C - WRITES:
        text = body(i)
        assert "truncated" in text, i
        if i not in UNCAPPED:
            assert "Select-Object -First 500" in text, i


def test_reads_change_nothing():
    for i in BATCH_11C - WRITES:
        text = body(i)
        for verb in ("Set-AD", "Disable-AD", "Enable-AD", "Move-ADObject", "Remove-AD", "New-AD", "Add-ADGroupMember",
                     "Set-ItemProperty", "Remove-Item", "Set-Content", "Out-File", "Clear-EventLog"):
            assert verb not in text, (i, verb)


def test_no_secret_attributes_or_banned_tools():
    for i in BATCH_11C:
        text = source(i)
        for bad in SECRET_ATTRS:
            assert bad.lower() not in text.lower(), (i, bad)
        assert not re.search(r"msDS-ManagedPassword(?!Interval)", text), i
        assert "gallery:" not in text, i
    msa = body("ad.managed_service_accounts")
    assert "PrincipalsAllowedToRetrieveManagedPassword" in msa and "Properties whenCreated" in msa


def test_writes_preview_and_validate():
    got = ids()
    for i in WRITES:
        assert got[i].preview and got[i].meta["preview"] == "plan", i
        text = source(i)
        assert "[switch]$Preview" in text and "if ($Preview)" in text and "changes = @(" in text and "current = " in text, i
    protect = body("ad.protect_ous")
    assert r"-cnotmatch '\AOU=[A-Za-z0-9 ._&()\\=,-]{1,1000}\z'" in protect and "-cnotmatch ',DC=[A-Za-z0-9-]+\z'" in protect
    sets = re.findall(r"Set-ADOrganizationalUnit[^\n]*", protect)
    assert len(sets) == 1 and "-ProtectedFromAccidentalDeletion $true" in sets[0]  # only ever turns protection on
    assert "-gt 200" in protect


def test_move_computer_refuses_dcs_and_dc_ou():
    text = body("ad.move_computer")
    assert COMPUTER_RE in text
    assert r"-cnotmatch '\A(OU|CN)=[A-Za-z0-9 ._&()\\=,-]{1,1000}\z'" in text
    assert "Assert-HermesNotProtected $c" in text and "-band 8192" in text and "-band 67108864" in text
    assert "DomainControllersContainer" in text and "PolicyBlocked" in text
    assert "(sAMAccountName=$Name`$)" in text


def test_disable_stale_computers_is_bounded_and_rechecks_staleness():
    got = ids()["ad.disable_stale_computers"]
    days = next(p for p in got.params if p.name == "Days")
    assert days.minimum == 30 and days.default == 90
    text = body("ad.disable_stale_computers")
    assert COMPUTER_RE in text and "-gt 100" in text
    assert "Assert-HermesNotProtected $c" in text and "-band 8192" in text and "-band 67108864" in text
    assert "MSClusterVirtualServer/*" in text and "already disabled" in text
    assert "$c.LastLogonDate -ge $cut" in text and "$c.PasswordLastSet -ge $cut" in text and "$c.WhenCreated -ge $cut" in text
    assert "Remove-AD" not in text and "Set-ADComputer" not in text  # disable only, never delete or stamp


def test_identity_params_are_validated_and_ldap_escaped():
    for i in ("sessions.user_groups", "sessions.user_last_logon"):
        text = body(i)
        assert IDENTITY_RE in text and "ConvertTo-LdapValue $Identity" in text and "matches $($found.Count) users" in text, i
    find = body("sessions.find_user")
    assert r"-cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z'" in find
    assert "-ArgumentList @($want)" in find and "-Kind Any" in find and "quser 2>$null" in find


def test_dc_local_state_fans_out_to_every_dc():
    text = body("ad.no_client_site")
    assert "Get-ADDomainController -Filter *" in text and "Invoke-HermesCatalogFanout -Computers $dcs -ArgumentList @($MaxLines)" in text
    assert "Get-Content -LiteralPath $f -Tail $max" in text and "-ComputerName" not in text
    lines = next(p for p in ids()["ad.no_client_site"].params if p.name == "MaxLines")
    assert lines.maximum == 200000
    assert "-Server $dc.HostName" in body("sessions.user_last_logon")


def test_privileged_groups_resolved_by_sid():
    for i in ("ad.privileged_members", "ad.disabled_in_groups"):
        text = body(i)
        for sid in ("S-1-5-32-544", "S-1-5-32-548", "S-1-5-32-549", "S-1-5-32-550", "S-1-5-32-551", "$domSid-512"):
            assert sid in text, (i, sid)
        assert "(sAMAccountName=DnsAdmins)" in text, i
    assert "primaryGroupID=" in body("ad.privileged_members") and "$seen" in body("ad.privileged_members")
    assert "$domSid-525" in body("ad.protected_users")


def test_group_nesting_is_iterative_and_bounded():
    text = body("ad.group_nesting")
    assert "System.Collections.Stack" in text and "$cyclic" in text and "$hops -lt 20" in text
    assert "function " not in text  # no recursion


def test_disable_stale_computers_skips_seamless_sso_and_spn_holders():
    text = body("ad.disable_stale_computers")
    assert "$n -ieq 'AZUREADSSOACC'" in text and "Seamless SSO" in text
    assert r"-notmatch '\A(?i:HOST|RestrictedKrbHost|TERMSRV|WSMAN)/'" in text and "holds non-default service principal names" in text
    # the skip reasons are decided before anything is disabled and shown as skipped rows
    assert text.index("AZUREADSSOACC") < text.index("Disable-ADAccount") and 'result = "skipped: $($p.reason)"' in text


def test_find_user_reports_the_host_cap():
    text = body("sessions.find_user")
    assert "eligible_hosts = $eligibleCount" in text and "hosts_capped = $hostsCapped" in text
    assert "truncated = ((@($fan.items).Count -gt 500) -or $hostsCapped)" in text
