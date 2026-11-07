import re

from sysadmin import catalog
import sysadmin.ops  # noqa: F401  (registers the shipped catalog)

BATCH_11E = {
    "gpo.wmi_filters", "gpo.blocked_inheritance", "gpo.recently_changed", "gpo.scripts", "gpo.settings_search",
    "gpo.processing_errors", "gpo.client_status",
    "events.group_membership_changes", "events.account_changes", "events.kerberos_preauth_failures", "events.dc_errors",
    "events.audit_tampering", "events.ntlm_logons", "events.service_crashes", "events.logon_types",
    "events.scheduled_task_changes", "events.defender_detections", "events.powershell_suspicious",
    "patch.patch_level", "patch.wu_health", "patch.office_c2r", "patch.install_failures",
    "files.share_permissions", "files.broad_write_access", "files.owner_report", "files.largest_files", "files.recent_files",
}
DC = {
    "gpo.wmi_filters", "gpo.blocked_inheritance", "gpo.recently_changed", "gpo.scripts", "gpo.settings_search",
    "events.group_membership_changes", "events.account_changes", "events.kerberos_preauth_failures", "events.dc_errors",
    "files.share_permissions", "files.broad_write_access", "files.owner_report", "files.largest_files", "files.recent_files",
}
DC_EVENT_FANOUT = {"events.group_membership_changes", "events.account_changes", "events.kerberos_preauth_failures", "events.dc_errors"}
EVENT_READERS = {i for i in BATCH_11E if "Get-WinEvent" in (catalog.CATALOG_DIR / i.split(".")[0] / f"{i.split('.')[1]}.ps1").read_text()}
FILES = {i for i in BATCH_11E if i.startswith("files.")}
WALKERS = FILES - {"files.share_permissions"}
CATEGORY = {"gpo": "Group Policy", "events": "Event logs", "patch": "Patching", "files": "File permissions"}
SERVER_RE = r"-cnotmatch '\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z'"
PATH_RE = r"""$Path -cnotmatch '\A[A-Za-z]:\\[^:*?<>|"\x00-\x1f]*\z' -or (@($Path -split '[\\/]') -contains '..')"""


def ids():
    return {o.meta["id"]: o for o in catalog.entries()}


def source(entry_id):
    area, name = entry_id.split(".")
    return (catalog.CATALOG_DIR / area / f"{name}.ps1").read_text()


def body(entry_id):
    return source(entry_id).split("#>", 1)[1]


def test_batch_present_read_only_with_targets_and_categories():
    got = ids()
    assert len(BATCH_11E) == 27 and BATCH_11E <= set(got)
    for i in BATCH_11E:
        op = got[i]
        assert op.tier == "R" and not op.preview and not op.destructive, i
        assert op.meta["target"] == ("dc" if i in DC else "endpoint"), i
        assert op.meta["category"] == CATEGORY[i.split(".")[0]], i
        assert op.meta["module"].startswith("inbox:"), i
        assert "[switch]$Preview" not in source(i), i
    # Covered elsewhere: the typed gpo_rsop tool, endpoint.os_version and endpoint.pending_reboot.
    assert "gpo.applied" not in got and "patch.os_build" not in got and "patch.pending_reboot" not in got


def test_header_columns_are_emitted_by_the_rows():
    for i in BATCH_11E:
        text = body(i)
        for col in ids()[i].meta["columns"]:
            if col == "host" and (ids()[i].meta["target"] == "endpoint" or "Invoke-HermesCatalogFanout" in text):
                continue  # added by the fan-out
            assert re.search(rf"(\b|'){col}('\]|\s*=)", text), (i, col)


def test_reads_change_nothing():
    write = re.compile(r"\b(Set-|Remove-|New-Item|Clear-|Restart-|Stop-|Start-Service|Disable-|Enable-|Rename-|Move-|"
                       r"Add-|Register-|Invoke-GPUpdate|wevtutil|gpupdate|Out-File|Export-)", re.I)
    for i in BATCH_11E:
        assert not write.search(body(i)), i


def test_event_readers_treat_no_events_as_empty_and_are_bounded():
    assert len(EVENT_READERS) >= 14
    for i in EVENT_READERS:
        text = body(i)
        assert "FullyQualifiedErrorId" in text and "NoMatching" in text, i
        assert "-MaxEvents" in text, i
        assert "-ComputerName" not in text, i
    for i in DC_EVENT_FANOUT:
        text = body(i)
        assert "Get-ADDomainController -Filter *" in text and "Invoke-HermesCatalogFanout -Computers $dcs" in text, i
        assert "capped_dcs" in text and "truncated" in text and "Select-Object -First 500" in text, i


def test_event_entries_never_return_script_or_task_content():
    ps = body("events.powershell_suspicious")
    assert "$d.Remove('ScriptBlockText')" in ps and ".Length" in ps
    assert not re.search(r"\b(text|script|content)\s*=", ps)
    tasks = body("events.scheduled_task_changes")
    assert "$n.Name -ne 'TaskContent' -and $n.Name -ne 'TaskContentNew'" in tasks
    ntlm = body("events.ntlm_logons")
    assert "AuthenticationPackageName']='NTLM'" in ntlm and "[int64]$h * 3600000" in ntlm


def test_gpo_scripts_never_show_parameters():
    text = body("gpo.scripts")
    assert "has_parameters = (" in text and "params = $" not in text and "parameters = $" not in text
    assert "Get-HermesSysvolPath -Child Policies" in text
    assert "-notmatch '\\.\\.'" in text  # no .. in the existence check path


def test_gpo_settings_search_validates_and_hides_secrets():
    op = ids()["gpo.settings_search"]
    kw = next(p for p in op.params if p.name == "Keyword")
    mx = next(p for p in op.params if p.name == "MaxGpos")
    assert kw.required and (mx.default, mx.maximum) == (200, 1000)
    text = body("gpo.settings_search")
    assert r"$Keyword -cnotmatch '\A[A-Za-z0-9 ._\\/:{}-]{2,64}\z'" in text
    assert "$a.LocalName -ne 'cpassword'" in text
    assert "cpassword|token" in text and "(hidden" not in text
    assert "IndexOf($Keyword, $cmp)" in text and "-match $Keyword" not in text and "-like" not in text.split("$secret =")[1].split("$dcName")[0]
    assert "if ($hits -ge 20) { break }" in text


def test_gpo_dc_reads_cap_rows():
    for i in ("gpo.wmi_filters", "gpo.blocked_inheritance", "gpo.recently_changed", "gpo.scripts", "gpo.settings_search"):
        text = body(i)
        assert "Select-Object -First 500" in text and "truncated" in text, i


def test_file_entries_validate_inputs_and_run_on_the_server():
    for i in FILES:
        text = body(i)
        assert SERVER_RE in text and "Invoke-HermesCatalogFanout -Computers @($Server)" in text, i
        assert "truncated" in text and "Select-Object -First 500" in text, i
    for i in WALKERS:
        text = body(i)
        assert PATH_RE in text, i
        assert "ReparsePoint" in text and "Path is a reparse point" in text and "-lt 2000" in text, i
        assert "skipped" in text and "folders_visited" in text, i
        depth = next(p for p in ids()[i].params if p.name == "Depth")
        assert depth.maximum == 5 and depth.minimum == 0, i
    for i in ("files.largest_files", "files.recent_files"):
        assert "-lt 100000" in body(i) and "files_examined" in body(i), i
    share = body("files.share_permissions")
    assert r"""$Share -cnotmatch '\A[^\\/:*?"<>|\[\]=;,+\x00-\x1f]{1,80}\z'""" in share
    assert "Translate([System.Security.Principal.SecurityIdentifier])" in share


def test_broad_access_matches_by_sid():
    for i in ("files.broad_write_access", "files.share_permissions"):
        text = body(i)
        assert "@('S-1-1-0', 'S-1-5-7', 'S-1-5-11', 'S-1-5-32-545')" in text and r"-513\z'" in text, i
        assert "0x500D0156" in text, i


def test_patch_entries_read_only_and_flag_fleet_outliers():
    wu = body("patch.wu_health")
    assert "Microsoft.Update.AutoUpdate" in wu and ".Results" in wu
    assert not re.search(r"DetectNow|\.Search\(|Download|Install\(", wu)
    assert "duplicate_client_id" in wu
    pl = body("patch.patch_level")
    assert "newest_in_result" in pl and "$fan.summary['behind']" in pl


def test_no_secret_sources():
    banned = re.compile(r"ms-Mcs-AdmPwd|msLAPS-|Get-LapsADPassword|Get-AdmPwdPassword|msFVE-RecoveryPassword|"
                        r"key=clear|DSInternals|Install-Module|Invoke-Expression", re.I)
    for i in BATCH_11E:
        assert not banned.search(source(i)), i


def test_gpo_settings_search_never_indexes_arguments_or_probes_secrets():
    text = body("gpo.settings_search")
    for a in ("'cpassword'", "'arguments'", "'args'", "'parameters'", "'runas'", "'cmdline'"):
        assert a in text.split("$noIndexAttr = @(")[1].split(")")[0], a
    assert "$noIndexEl = '\\A(?i:Parameters|Arguments|Args|Params|CommandLine|CmdLine|RunAs|cpassword|Password)\\z'" in text
    assert "if ($inside) { continue }" in text and "$noIndexAttr -notcontains" in text
    # a secret-classed setting emits no row at all, so prefix probing cannot work
    gate = "$setName -match $secret) { continue }"
    assert gate in text and text.index(gate) < text.index("$rows += @{")
    # script commands are only searched when they are a bare path
    assert "'\\A(?i:Command)\\z'" in text and "$txt -notmatch $pathLike" in text


def test_gpo_scripts_hide_inline_command_lines():
    op = ids()["gpo.scripts"]
    assert "inline_command" in op.meta["columns"]
    text = body("gpo.scripts")
    assert "script = $(if ($inline) { '[hidden: inline command]' } else { $cmd })" in text
    assert "$inline = ($cmd -notmatch $pathLike -or $cmd -match '\\s[/-]' -or $cmd.Length -gt 300)" in text
