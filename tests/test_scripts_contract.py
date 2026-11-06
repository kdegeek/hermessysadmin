import re
import shutil
import subprocess
from pathlib import Path

import pytest

from sysadmin import ops  # noqa: F401
from sysadmin.registry import OPS
from sysadmin.runner import SCRIPTS_DIR

ROOT = Path(__file__).resolve().parent.parent
REAL_OPS = [op for op in OPS.values() if not op.name.startswith("t_")]
FORBIDDEN = re.compile(
    r"Invoke-Expression|\biex\b|Add-Type|DownloadString|Start-Process"
    r"|\[scriptblock\]::Create|NewScriptBlock|InvokeScript|\bInvoke-Command\b",
    re.IGNORECASE,
)
# Windows PowerShell 5.1 is the target; pwsh 7 parses these but 5.1 does not.
PS7_ONLY = re.compile(r"\?\?|\?\.|&&|\|\|")


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


@pytest.mark.parametrize("op", REAL_OPS, ids=lambda o: o.name)
def test_every_op_has_a_contract_conforming_script(op):
    path = SCRIPTS_DIR / f"{op.script}.ps1"
    assert path.is_file(), f"missing {path.name}"
    text = path.read_text(encoding="utf-8")
    block = _param_block(text)
    body = _code(text).lstrip()[len(block):].lstrip()
    assert body.startswith("Invoke-Op {"), "the script body must be a single Invoke-Op { ... } block"
    assert body.rstrip().endswith("}"), "nothing may follow the Invoke-Op block"
    assert not FORBIDDEN.search(_code(text)), "forbidden construct"
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
def test_all_scripts_parse():
    result = subprocess.run(
        ["pwsh", "-NoProfile", "-File", str(ROOT / "scripts" / "ps_parse_check.ps1"), "-Path", str(SCRIPTS_DIR)],
        capture_output=True, text=True, timeout=120,
    )
    assert result.returncode == 0, result.stdout + result.stderr
