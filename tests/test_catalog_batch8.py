import re
import shutil
import subprocess

import pytest

from sysadmin import catalog
import sysadmin.ops  # noqa: F401  (registers the shipped catalog)

BATCH_8 = {"security.defender_status", "security.bitlocker_status", "security.firewall_profiles",
           "security.local_admins", "security.laps_status", "security.smb1", "security.tls_protocols",
           "security.rdp_nla", "security.guest_account", "security.secure_boot_tpm", "security.applocker_wdac",
           "patch.hotfix_history", "patch.pending_updates", "patch.wu_config", "patch.trigger_scan",
           "patch.wu_history", "patch.wu_install"}
PWSH = shutil.which("pwsh") or ("/opt/homebrew/bin/pwsh" if shutil.os.path.exists("/opt/homebrew/bin/pwsh") else None)


def ids():
    return {o.meta["id"]: o for o in catalog.entries()}


def source(entry_id):
    area, name = entry_id.split(".")
    return (catalog.CATALOG_DIR / area / f"{name}.ps1").read_text()


def body(entry_id):
    return source(entry_id).split("#>", 1)[1]


def test_batch_8_present():
    got = ids()
    assert BATCH_8 <= set(got)
    assert got["patch.wu_install"].tier == "H" and got["patch.wu_install"].meta["module"] == "inbox:ScheduledTasks"
    assert got["patch.wu_history"].meta["module"] == "inbox:WindowsUpdateAgent"
    assert got["patch.pending_updates"].meta["module"] == "inbox:WindowsUpdateAgent"
    assert {i for i in BATCH_8 if got[i].tier != "R"} == {"patch.trigger_scan", "patch.wu_install"}
    assert got["patch.trigger_scan"].tier == "W"


def test_no_secret_cmdlets_anywhere():
    banned = ("Get-LapsADPassword", "Get-AdmPwdPassword", "Get-BitLockerRecoveryKey", "msFVE-RecoveryPassword",
              "ms-Mcs-AdmPwd", "msLAPS-Password", "Get-RequestArchivedKey", "cpassword =", "Invoke-WUJob")
    for f in catalog.CATALOG_DIR.glob("*/*.ps1"):
        text = f.read_text()
        assert not [b for b in banned if b in text], f


def test_bitlocker_reads_no_protector_methods():
    text = body("security.bitlocker_status")
    assert "RecoveryPassword" not in text and "KeyProtector" not in text


def test_no_entry_uses_pswindowsupdate():
    for f in catalog.CATALOG_DIR.glob("*/*.ps1"):
        assert "PSWindowsUpdate" not in f.read_text(), f
    assert not (catalog.CATALOG_DIR / "patch" / "wu_pending.ps1").exists()


def test_wu_history_maps_result_and_operation_codes():
    code = body("patch.wu_history")
    for needle in ("GetTotalHistoryCount()", "QueryHistory(0,", "succeeded_with_errors", "in_progress", "aborted",
                   "'install'", "'uninstall'", "KB\\d"):
        assert needle in code, needle


def test_wu_install_uses_constant_encoded_task_body():
    code = body("patch.wu_install")
    for needle in ("Register-ScheduledTask", "New-ScheduledTaskAction -Execute 'powershell.exe'",
                   "-NoProfile -NonInteractive -EncodedCommand", "New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest",
                   "Start-ScheduledTask", "HermesSysadmin-WUInstall", "$env:ProgramData", "WUInstall.log", "-AllowStartIfOnBatteries -DontStopIfGoingOnBatteries",
                   "IsDownloaded", "CanRequestUserInput", "Unregister-ScheduledTask -TaskName 'HermesSysadmin-WUInstall' -Confirm:$false", "an install is already running",
                   "0FA1201D-4330-4FA8-8AE9-B877473B6441", "E6CF1350-C01B-414D-A61F-263D14D133B4",
                   "[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))"):
        assert needle in code, needle
    # The template is a single-quoted here-string, so nothing from the caller can be interpolated into it.
    assert "$bodyTemplate = @'" in code
    # Category is validated against the fixed set before use.
    assert "-notin @('security', 'critical', 'both')" in code


def test_pending_updates_reports_access_denied_per_host():
    code = body("patch.pending_updates")
    assert "0x80070005" in code and "throw" in code


@pytest.mark.skipif(PWSH is None, reason="pwsh not available")
@pytest.mark.parametrize("category,reboot", [("security", "$false"), ("critical", "$true"), ("both", "$true")])
def test_wu_install_task_body_parses_for_each_variant(category, reboot, tmp_path):
    code = body("patch.wu_install")
    tmpl = re.search(r"\$bodyTemplate = @'\n(.*?)\n'@", code, re.S).group(1)
    assert "__GUIDS__" in tmpl and "__REBOOT__" in tmpl
    guids = {"security": "'0FA1201D-4330-4FA8-8AE9-B877473B6441'", "critical": "'E6CF1350-C01B-414D-A61F-263D14D133B4'"}
    quoted = guids.get(category, ",".join(guids.values()))
    reboot_yes = re.search(r"\$rebootYes = (.+)", code).group(1)
    reboot_no = re.search(r"\$rebootNo = (.+)", code).group(1)
    rb = reboot_yes if reboot == "$true" else reboot_no
    script = tmp_path / "gen.ps1"
    script.write_text(
        f"$rb = {rb}\n$t = @'\n{tmpl}\n'@\n"
        f"$b = $t.Replace('__GUIDS__', \"{quoted}\").Replace('__REBOOT__', $rb)\n"
        "$e = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($b, [ref]$null, [ref]$e)\n"
        "if ($e.Count -gt 0) { $e | ForEach-Object { $_.Message }; exit 1 }\n"
        "if ($b -match '__') { 'placeholder left'; exit 1 }\n'ok'\n")
    out = subprocess.run([PWSH, "-NoProfile", "-File", str(script)], capture_output=True, text=True)
    assert out.stdout.strip() == "ok", out.stdout + out.stderr


def test_laps_checks_csp_then_gpo_then_local_and_reports_source():
    code = body("security.laps_status")
    csp, gpo, local = (code.index(p) for p in ("Microsoft\\Policies\\LAPS", "CurrentVersion\\Policies\\LAPS", "CurrentVersion\\LAPS\\Config"))
    assert csp < gpo < local
    assert "source =" in code and "'disabled'" in code


def test_rdp_nla_policy_override_and_source():
    code = body("security.rdp_nla")
    assert "Policies\\Microsoft\\Windows NT\\Terminal Services" in code and "'policy'" in code and "'local'" in code


def test_laps_first_root_with_any_value_wins_and_missing_backup_means_disabled():
    code = body("security.laps_status")
    assert "-notlike 'PS*'" in code and "else { 0 }" in code
    loop = code[code.index("foreach ($s in $sources)"):code.index("$dirName")]
    assert loop.rstrip().endswith("break\n        }") or "break" in loop.split("$applied = $s.name")[1]
