import re
import shutil
import subprocess
from pathlib import Path

import pytest

from sysadmin import ops  # noqa: F401
from sysadmin.registry import OPS
from sysadmin.runner import SCRIPTS_DIR

ROOT = Path(__file__).resolve().parent.parent
REAL_OPS = [op for op in OPS.values() if not op.name.startswith("t_") and op.local is None and not op.catalog]
FORBIDDEN = re.compile(
    r"Invoke-Expression|\biex\b|Add-Type|DownloadString|Start-Process"
    r"|\[scriptblock\]::Create|NewScriptBlock|InvokeScript|\bInvoke-Command\b",
    re.IGNORECASE,
)
NETWORK = re.compile(r"\bInvoke-WebRequest\b|\biwr\b|\bInvoke-RestMethod\b|\birm\b", re.IGNORECASE)
WEB_ALLOWED = {"catalog_module_install"}  # the only script that downloads (pinned, hash-verified Gallery packages)
# Windows PowerShell 5.1 is the target; pwsh 7 parses these but 5.1 does not.
PS7_ONLY = re.compile(r"\?\?|\?\.|&&|\|\|")


def _forbidden(text: str, stem: str = "", core: bool = False) -> bool:
    code = _code(text)
    if FORBIDDEN.search(code):
        return True
    if core and stem in WEB_ALLOWED:
        return bool(re.search(r"\biwr\b|\bInvoke-RestMethod\b|\birm\b", code, re.IGNORECASE))
    return bool(NETWORK.search(code))


def _code(text: str) -> str:
    text = re.sub(r"<#.*?#>", "", text, flags=re.S)
    return "\n".join(line for line in text.splitlines() if not line.strip().startswith("#"))


def _param_block(text: str) -> str:
    code = _code(text).lstrip()
    assert code.lower().startswith("param("), "script must start with a param() block"
    depth = 0
    for i, ch in enumerate(code):
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return code[: i + 1]
    raise AssertionError("unterminated param block")


CATALOG_FILES = sorted((ROOT / "catalog").glob("*/*.ps1"))


@pytest.mark.parametrize("path", CATALOG_FILES, ids=lambda p: f"{p.parent.name}/{p.name}")
def test_every_catalog_script_conforms(path):
    text = path.read_text(encoding="utf-8")
    block = _param_block(text)
    body = _code(text).lstrip()[len(block):].lstrip()
    assert body.startswith("Invoke-Op {"), "the script body must be a single Invoke-Op { ... } block"
    assert body.rstrip().endswith("}"), "nothing may follow the Invoke-Op block"
    assert not _forbidden(text), "forbidden construct"
    assert not PS7_ONLY.search(_code(text)), "PowerShell 7-only operator (target is 5.1)"


@pytest.mark.parametrize("op", REAL_OPS, ids=lambda o: o.name)
def test_every_op_has_a_contract_conforming_script(op):
    path = SCRIPTS_DIR / f"{op.script}.ps1"
    assert path.is_file(), f"missing {path.name}"
    text = path.read_text(encoding="utf-8")
    block = _param_block(text)
    body = _code(text).lstrip()[len(block):].lstrip()
    assert body.startswith("Invoke-Op {"), "the script body must be a single Invoke-Op { ... } block"
    assert body.rstrip().endswith("}"), "nothing may follow the Invoke-Op block"
    assert not _forbidden(text, op.script, core=True), "forbidden construct"
    assert not PS7_ONLY.search(_code(text)), "PowerShell 7-only operator (target is 5.1)"
    for p in op.params:
        assert re.search(rf"\${p.ps_name}\b", block, re.IGNORECASE), f"param ${p.ps_name} not declared"
    if op.preview:
        assert re.search(r"\[switch\]\$Preview\b", block), "preview ops must declare [switch]$Preview"
    if op.inject is not None:
        from sysadmin.config import Settings

        for name in op.inject(Settings()):
            assert re.search(rf"\${name}\b", block, re.IGNORECASE), f"injected ${name} not declared"


def test_no_orphan_scripts():
    scripts = {p.stem for p in SCRIPTS_DIR.glob("*.ps1")} - {"_prelude"}
    assert scripts == {op.script for op in REAL_OPS}


@pytest.mark.skipif(shutil.which("pwsh") is None, reason="pwsh not installed")
@pytest.mark.parametrize("directory", [SCRIPTS_DIR, ROOT / "catalog"], ids=["scripts", "catalog"])
def test_all_scripts_parse(directory):
    result = subprocess.run(
        ["pwsh", "-NoProfile", "-File", str(ROOT / "scripts" / "ps_parse_check.ps1"), "-Path", str(directory)],
        capture_output=True, text=True, timeout=120,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_group_member_scripts_resolve_uniquely_and_change_resolved_objects():
    for name, cmd in (("ad_group_add_member", "Add-ADGroupMember"), ("ad_group_remove_member", "Remove-ADGroupMember")):
        text = (SCRIPTS_DIR / f"{name}.ps1").read_text(encoding="utf-8")
        assert "Resolve-HermesMember" in text and "cn=" not in text
        assert f"{cmd} -Identity $g -Members $dns" in text


def test_web_download_is_confined_to_the_module_installer():
    carriers = [p.stem for p in SCRIPTS_DIR.glob("*.ps1") if re.search(r"\bInvoke-WebRequest\b", _code(p.read_text(encoding="utf-8")), re.I)]
    assert carriers == ["catalog_module_install"]
    assert _forbidden("Invoke-WebRequest -Uri x", "some_other_script", core=True)
    assert _forbidden("Invoke-WebRequest -Uri x", "catalog_module_install", core=False)
    assert _forbidden("irm x", "catalog_module_install", core=True)
    assert not _forbidden("Invoke-WebRequest -Uri x", "catalog_module_install", core=True)


# --- DC locality (Task 17) ---------------------------------------------------------------------
# Over WinRM the session runs ON a DC; over the local transport it runs on the Hermes machine. Code outside
# a fan-out / Invoke-HermesOnDc scriptblock must not read DC-local state directly.
DC_LOCAL = re.compile(
    r"\$env:COMPUTERNAME|SYSVOL\\domain|\\SYSVOL\b|NTDS\\|HermesSysadmin\\GpoBackups"
    r"|\bGet-WinEvent\b|\bGet-EventLog\b|\bwbadmin\b|\brepadmin\b|\bdcdiag\b|\bw32tm\b|\bdfsrdiag\b"
    r"|\bGet-Service\b|\bGet-CimInstance\b|\bGet-WmiObject\b|\bGet-SmbShare\b|\bGet-WB\w+|\$Global:HermesLocalDc",
    re.IGNORECASE,
)
# Waivers, each with its reason.
DC_LOCAL_ALLOWED = {
    "ad_connection_test": "describes the machine PowerShell runs on, on purpose",
    "backup_cancel": "wbadmin runs inside the fan-out; the name only appears in the error message",
}
_REMOTE_BLOCK = re.compile(
    r"\b(Get-HermesFanout|Invoke-HermesOne|Invoke-HermesCatalogFanout|Invoke-HermesOnDc)\b[^\n]*?-Script\s*\{"
)


def _outside_remote_blocks(code: str) -> str:
    """The code with every fan-out / Invoke-HermesOnDc scriptblock body removed (balanced braces)."""
    out, pos = [], 0
    for m in _REMOTE_BLOCK.finditer(code):
        if m.start() < pos:
            continue
        out.append(code[pos:m.end()])
        depth, i = 1, m.end()
        while i < len(code) and depth:
            depth += {"{": 1, "}": -1}.get(code[i], 0)
            i += 1
        pos = i - 1
    out.append(code[pos:])
    return "".join(out)


def test_remote_block_stripper():
    code = "a; Invoke-HermesOnDc -ArgumentList @(1) -Script { Get-WinEvent; if ($x) { w32tm } }; Get-Service"
    stripped = _outside_remote_blocks(code)
    assert "Get-WinEvent" not in stripped and "w32tm" not in stripped and "Get-Service" in stripped


DC_SCRIPTS = [p for p in sorted(SCRIPTS_DIR.glob("*.ps1")) if p.stem != "_prelude"] + [
    p for p in CATALOG_FILES if re.search(r"^target:\s*dc\s*$", p.read_text(encoding="utf-8"), re.M)
]


@pytest.mark.parametrize("path", DC_SCRIPTS, ids=lambda p: f"{p.parent.name}/{p.name}")
def test_no_dc_local_reads_outside_the_dc_helpers(path):
    if path.stem in DC_LOCAL_ALLOWED and path.parent == SCRIPTS_DIR:
        return
    outside = _outside_remote_blocks(_code(path.read_text(encoding="utf-8")))
    hits = sorted({m.group(0) for m in DC_LOCAL.finditer(outside)})
    assert not hits, f"DC-local state read on the session host: {hits}; use Invoke-HermesOnDc, Get-HermesDc, Get-HermesSysvolPath or a fan-out"


@pytest.mark.parametrize("path", DC_SCRIPTS, ids=lambda p: f"{p.parent.name}/{p.name}")
def test_dns_server_cmdlets_target_the_dc(path):
    outside = _outside_remote_blocks(_code(path.read_text(encoding="utf-8")))
    for line in outside.splitlines():
        if re.search(r"\b(Get|Set|Add|Remove)-DnsServer\w+\s", line) and "Get-Command" not in line:
            assert re.search(r"@dns\b", line, re.I), f"DnsServer cmdlet without the @dns (Get-HermesDcTarget) splat: {line.strip()}"


def test_backup_scripts_tolerate_a_null_service_credential():
    for name in ("backup_start", "backup_set_policy"):
        text = (SCRIPTS_DIR / f"{name}.ps1").read_text(encoding="utf-8")
        assert "-Credential $C" not in text, f"{name}: build the New-WBBackupTarget splat; HermesCred is $null in local mode"
