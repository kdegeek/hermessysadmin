import re
import shutil
import subprocess

import pytest

from sysadmin import catalog
import sysadmin.ops  # noqa: F401  (registers the shipped catalog)

BATCH_7 = {"endpoint.pending_reboot", "endpoint.top_processes", "endpoint.stopped_auto_services",
           "endpoint.installed_software", "endpoint.startup_items", "endpoint.recent_errors", "endpoint.hardware",
           "endpoint.battery", "sessions.logged_on", "sessions.user_profiles", "maint.gpupdate",
           "maint.restart_service", "maint.flush_dns", "maint.clear_temp"}
PWSH = shutil.which("pwsh") or ("/opt/homebrew/bin/pwsh" if shutil.os.path.exists("/opt/homebrew/bin/pwsh") else None)


def ids():
    return {o.meta["id"]: o for o in catalog.entries()}


def body(name):
    text = (catalog.CATALOG_DIR / "maint" / name).read_text()
    return text.split("#>", 1)[1]


def test_batch_7_present_with_tiers():
    got = ids()
    assert BATCH_7 <= set(got)
    assert {i for i in BATCH_7 if got[i].tier != "R"} == {"maint.gpupdate", "maint.restart_service",
                                                          "maint.flush_dns", "maint.clear_temp"}


def test_restart_service_denylist_is_in_script_body():
    script = body("restart_service.ps1")
    for name in ("winrm", "rpcss", "lsm", "termservice"):
        assert f"'{name}'" in script
    assert "throw" in script


def test_clear_temp_never_follows_reparse_points():
    assert "ReparsePoint" in body("clear_temp.ps1")


@pytest.mark.skipif(PWSH is None, reason="pwsh not available")
def test_restart_service_validation_in_pwsh():
    script = body("restart_service.ps1")
    rx = re.search(r"-cnotmatch '([^']+)'", script).group(1)
    deny = re.search(r"@\(('winrm'[^)]*)\)", script).group(1)
    cmd = (f"foreach ($n in @('WinRM', \"Spooler`n\", 'Spooler', 'rpcsS')) {{ "
           f"$ok = $n -cmatch '{rx}'; $den = @({deny}) -contains $n.ToLowerInvariant(); "
           f"\"$ok/$den\" }}")
    out = subprocess.run([PWSH, "-NoProfile", "-Command", cmd], capture_output=True, text=True, check=True).stdout.split()
    assert out == ["True/True", "False/False", "True/False", "True/True"]
