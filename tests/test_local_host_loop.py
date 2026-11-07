"""Runs the real LocalTransport host loop under pwsh (skipped when pwsh is missing)."""

import json
import shutil

import pytest

from sysadmin.config import Settings
from sysadmin.errors import RemoteScriptError, Timeout
from sysadmin.local_transport import LocalTransport, popen_process

PWSH = shutil.which("pwsh")
pytestmark = pytest.mark.skipif(PWSH is None, reason="pwsh not installed")

PRELUDE = r"""
param([string]$User, [string]$Pass)
$ErrorActionPreference = 'Stop'
$Global:HermesPreludeRuns = 1 + [int]$Global:HermesPreludeRuns
$PreludeLocal = 'dot-sourced into global scope'
function Global:Get-HermesTestValue { 'from-prelude' }
"""

ECHO = r"""
param([string[]]$Names, [switch]$Flag, [hashtable]$Changes, [string[]]$One, [string[]]$Empty, [int]$N)
Write-Host 'stray host output that must be ignored'
Write-Host -NoNewline 'no newline either'
[Console]::Out.Write('raw console noise')
ConvertTo-Json -Compress -Depth 5 -InputObject @{
    names = $Names; names_type = $Names.GetType().Name; flag = [bool]$Flag
    changes = $Changes; nested_type = $Changes.inner.GetType().Name; list_in_hash = @($Changes.list).Count
    one = $One; one_count = @($One).Count; empty_count = @($Empty).Count; n = $N
    prelude = (Get-HermesTestValue); runs = $Global:HermesPreludeRuns; eap = "$ErrorActionPreference"
    global_var = $PreludeLocal; unicode = 'Zoë ✓'
}
"""


@pytest.fixture
def transport():
    t = LocalTransport(Settings(transport="local", run_as="hermes_user"), PRELUDE,
                       process_factory=popen_process, powershell=PWSH, timeout=60, network_probe=None)
    yield t
    t.close()


def test_params_round_trip_and_framing(transport):
    params = {"Names": ["a", "b"], "Flag": True, "Changes": {"title": "x", "inner": {"k": 1}, "list": [1, 2, 3]},
              "One": ["solo"], "Empty": [], "N": 7}
    out = transport.invoke(ECHO, params)
    assert len(out) == 1
    data = json.loads(out[0])
    assert data["names"] == ["a", "b"] and data["names_type"] == "String[]"
    assert data["flag"] is True
    assert data["changes"]["title"] == "x" and data["changes"]["inner"] == {"k": 1}
    assert data["nested_type"] == "Hashtable" and data["list_in_hash"] == 3
    assert data["one"] == ["solo"] and data["one_count"] == 1 and data["empty_count"] == 0
    assert data["n"] == 7
    assert data["prelude"] == "from-prelude" and data["runs"] == 1
    assert data["eap"] == "Stop" and data["global_var"] == "dot-sourced into global scope"
    assert data["unicode"] == "Zoë ✓"
    # Second call: same process, prelude not re-run.
    assert json.loads(transport.invoke(ECHO, {**params, "N": 1})[0])["runs"] == 1


def test_non_strings_are_rendered_with_out_string(transport):
    out = transport.invoke("param() 'text'; 42; $null; [pscustomobject]@{ a = 1 }", {})
    assert out[0] == "text" and out[1] == "42"
    assert "a" in out[2] and "1" in out[2] and len(out) == 3


def test_non_terminating_errors_without_output_raise(transport):
    with pytest.raises(RemoteScriptError, match="first problem"):
        transport.invoke("param() $ErrorActionPreference = 'Continue'; Write-Error 'first problem'; Write-Error 'second'", {})
    # The process survives a script error.
    assert transport.invoke("param() 'still alive'", {}) == ["still alive"]


def test_terminating_error_without_output_raises(transport):
    with pytest.raises(RemoteScriptError, match="kaboom"):
        transport.invoke("param() throw 'kaboom'", {})


def test_syntax_error_is_reported_not_fatal(transport):
    with pytest.raises(RemoteScriptError):
        transport.invoke("param( 'unterminated", {})
    assert transport.invoke("param() 'ok'", {}) == ["ok"]


def test_errors_with_output_return_the_output(transport):
    out = transport.invoke("param() $ErrorActionPreference = 'Continue'; Write-Error 'soft'; '{\"ok\":true}'", {})
    assert out == ['{"ok":true}']


def test_invoke_op_style_json_result(transport):
    script = "param([string]$Who) ConvertTo-Json -Compress -InputObject @{ ok = $true; data = @{ who = $Who } }"
    assert json.loads(transport.invoke(script, {"Who": "bob"})[0]) == {"ok": True, "data": {"who": "bob"}}


def test_timeout_kills_and_restarts():
    t = LocalTransport(Settings(transport="local", run_as="hermes_user"), PRELUDE,
                       process_factory=popen_process, powershell=PWSH, timeout=3, network_probe=None)
    try:
        with pytest.raises(Timeout):
            t.invoke("param() Start-Sleep -Seconds 30", {})
        assert t.invoke("param() 'back'", {}) == ["back"]
    finally:
        t.close()


# --- the real prelude through the real host loop (local mode: no credential) -----------------

from sysadmin.runner import load_prelude  # noqa: E402

PROBE = r"""
param()
$keys = @($Global:PSDefaultParameterValues.Keys | ForEach-Object { "$_" })
$out = @{
    cred_is_null = ($null -eq $Global:HermesCred)
    credential_defaults = @($keys | Where-Object { $_ -like '*:Credential' }).Count
    gp_pin_is_lazy = ($Global:PSDefaultParameterValues['*-GP*:Server'] -is [scriptblock])
    ad_pin_is_lazy = ($Global:PSDefaultParameterValues['*-AD*:Server'] -is [scriptblock])
    is_dc = $Global:HermesIsDc
    user_var = [bool](Get-Variable -Name User -Scope Global -ErrorAction SilentlyContinue)
}
# Fake a discovered DC and the AD module, then exercise the helpers both ways.
$Global:HermesDc = 'dc9.corp.example'
function Global:Get-ADDomain { [pscustomobject]@{ DNSRoot = 'corp.example' } }
$out.remote_target = (Get-HermesDcTarget).ComputerName
$out.remote_sysvol = Get-HermesSysvolPath -Child Policies
$Global:HermesIsDc = $true
$out.dc_target_count = (Get-HermesDcTarget).Count
$out.inline = Invoke-HermesOnDc -ArgumentList @('a', 'b') -Script { param($x, $y) "$x+$y" }
$out.dc_value = Get-HermesDc
# Discovery with the lazy AD pin in place: a fake AD module whose Discover set has no -Server.
$Global:HermesDc = $null
function Global:Get-ADDomainController {
    [CmdletBinding(DefaultParameterSetName = 'Identity')]
    param([Parameter(ParameterSetName = 'Identity')][string]$Server, [Parameter(ParameterSetName = 'Discover')][switch]$Discover,
          [Parameter(ParameterSetName = 'Discover')][string]$Service)
    if ($Discover) { [pscustomobject]@{ HostName = @("pdc.corp.example") } } else { [pscustomobject]@{ HostName = @("server=$Server") } }
}
$out.discovered = Get-HermesDc
$out.pinned = "$(@((Get-ADDomainController).HostName)[0])"
$out.disabled_restored = -not $Global:PSDefaultParameterValues.ContainsKey('Disabled')
ConvertTo-Json -Compress -InputObject $out
"""


def test_real_prelude_in_local_mode_sets_no_credential_and_dc_helpers_work():
    t = LocalTransport(Settings(transport="local", run_as="hermes_user"), load_prelude(),
                       process_factory=popen_process, powershell=PWSH, timeout=60, network_probe=None)
    try:
        data = json.loads(t.invoke(PROBE, {})[0])
    finally:
        t.close()
    assert data["cred_is_null"] is True and data["credential_defaults"] == 0
    assert data["gp_pin_is_lazy"] is True and data["is_dc"] is False
    assert data["user_var"] is False
    assert data["remote_target"] == "dc9.corp.example"
    assert data["remote_sysvol"] == "\\\\dc9.corp.example\\SYSVOL\\corp.example\\Policies"
    assert data["dc_target_count"] == 0 and data["inline"] == "a+b"
    assert data["dc_value"] == "dc9.corp.example"
    assert data["ad_pin_is_lazy"] is True
    assert data["discovered"] == "pdc.corp.example" and data["pinned"] == "server=pdc.corp.example"
    assert data["disabled_restored"] is True


def test_loop_state_is_invisible_to_scripts(transport):
    probe = ("param() ConvertTo-Json -Compress -InputObject @{ sentinel = \"$__hsSentinel\"; out = [bool]$__hsOut; "
             "inp = [bool]$__hsIn; tag = \"$__hsTag\"; conv = [bool]$__hsConvert; line = \"$__hsLine\"; "
             "vars = @(Get-Variable -Name '__hs*' -ErrorAction SilentlyContinue).Count }")
    data = json.loads(transport.invoke(probe, {})[0])
    assert data == {"sentinel": "", "out": False, "inp": False, "tag": "", "conv": False, "line": "", "vars": 0}


DC_RESET = r"""
param([string]$Message, [bool]$OnDc)
$Global:HermesIsDc = $OnDc
$Global:HermesDc = 'dc1.corp.example'
$r = Invoke-Op { throw $Message }
ConvertTo-Json -Compress -InputObject @{ cleared = ($null -eq $Global:HermesDc); result = $r }
"""


@pytest.mark.parametrize("message,on_dc,cleared", [
    ("Unable to contact the server. This may be because this server does not exist.", False, True),
    ("The server is not operational.", False, True),
    ("Cannot find an object with identity 'bob'.", False, False),
    ("The server is not operational.", True, False),
])
def test_invoke_op_forgets_an_unreachable_dc(message, on_dc, cleared):
    t = LocalTransport(Settings(transport="local", run_as="hermes_user"), load_prelude(),
                       process_factory=popen_process, powershell=PWSH, timeout=60, network_probe=None)
    try:
        data = json.loads(t.invoke(DC_RESET, {"Message": message, "OnDc": on_dc})[0])
    finally:
        t.close()
    assert data["cleared"] is cleared
    assert json.loads(data["result"])["ok"] is False
