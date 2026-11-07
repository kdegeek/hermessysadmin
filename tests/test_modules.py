import json
from dataclasses import replace

import pytest

from sysadmin import catalog
from sysadmin.catalog import CATALOG_DIR
from sysadmin.ops import modules
from sysadmin.registry import OPS


SYNTHETIC = {"modules": [{
    "name": "FakeMod", "version": "1.2.3", "package_hash": "A" * 88, "hash_algorithm": "SHA512",
    "license": "MIT", "project_url": "https://example.invalid/fakemod", "signer": None, "requires": [],
}]}


@pytest.fixture
def synthetic_lock(tmp_path, monkeypatch):
    """Point the module ops at a temp lock holding one synthetic (never downloaded) module."""
    path = tmp_path / "modules.lock.json"
    path.write_text(json.dumps(SYNTHETIC), encoding="utf-8")
    monkeypatch.setattr(modules, "LOCK_PATH", path)
    return path


def test_shipped_lock_is_empty_and_ops_follow_it():
    # v0.2 ships no Gallery modules (double hop); the machinery stays for future local modules.
    shipped = json.loads((CATALOG_DIR / "modules.lock.json").read_text(encoding="utf-8"))
    assert shipped == {"modules": []}
    assert modules.lock_names() == ()
    op = OPS["catalog_module_install"]
    assert op.enabled is not None and op.enabled(None) is False
    assert OPS["catalog_module_status"].enabled is None


def test_install_is_high_risk_with_preview_and_is_enabled_once_a_module_is_pinned(synthetic_lock):
    op = OPS["catalog_module_install"]
    assert op.tier == "H" and op.preview
    assert modules.lock_names() == ("FakeMod",)
    assert op.enabled(None) is True


def test_install_disabled_with_an_empty_lock_is_blocked(make_service, runner):
    out = make_service().preview("catalog_module_install", {"name": "NTFSSecurity"})
    assert out["ok"] is False and not runner.calls


def test_install_preview_injects_lock(synthetic_lock, make_service, runner):
    runner.responses["catalog_module_install"] = {"summary": "s", "changes": [], "current": {}}
    make_service().preview("catalog_module_install", {"name": "FakeMod"})
    _, params, _ = runner.calls[-1]
    assert json.loads(params["Lock"])["modules"][0]["name"] == "FakeMod" and params["Preview"] is True


def test_status_is_a_cached_read_that_injects_the_lock(synthetic_lock, make_service, runner):
    status = {"root": "C:\\ProgramData\\HermesSysadmin\\Modules", "items": []}
    runner.responses["catalog_module_status"] = status
    svc = make_service()
    assert OPS["catalog_module_status"].tier == "R" and OPS["catalog_module_status"].params == ()
    assert svc.call("catalog_module_status", {}, actor="agent")["data"] == status
    svc.call("catalog_module_status", {}, actor="agent")
    assert len(runner.calls) == 1 and json.loads(runner.calls[0][1]["Lock"])["modules"]


def test_status_works_with_the_empty_shipped_lock(make_service, runner):
    runner.responses["catalog_module_status"] = {"root": "r", "items": []}
    make_service().call("catalog_module_status", {}, actor="agent")
    assert json.loads(runner.calls[0][1]["Lock"]) == {"modules": []}


def _gallery_entry(monkeypatch, module):
    base = OPS["catalog_get"]
    op = replace(base, name="cat.t", meta={"id": "t.entry", "title": "T", "category": "ad", "target": "dc", "module": module})
    monkeypatch.setattr(catalog, "entries", lambda: [op])


def test_catalog_get_reports_module_installed(monkeypatch, make_service, runner):
    _gallery_entry(monkeypatch, "gallery:FakeMod@1.2.3")
    runner.responses["catalog_module_status"] = {"root": "r", "items": [
        {"name": "FakeMod", "version": "1.2.3", "installed": True, "verified": True, "signer_ok": True}]}
    out = make_service().call("catalog_get", {"id": "t.entry"}, actor="agent")
    assert out["data"]["module_installed"] is True
    runner.responses["catalog_module_status"] = {"root": "r", "items": [
        {"name": "FakeMod", "version": "1.2.3", "installed": False, "verified": False, "signer_ok": None}]}
    assert make_service().call("catalog_get", {"id": "t.entry"}, actor="agent")["data"]["module_installed"] is False


def test_catalog_get_module_installed_is_null_on_error_or_inbox(monkeypatch, make_service, runner):
    _gallery_entry(monkeypatch, "gallery:FakeMod@1.2.3")
    runner.responses["catalog_module_status"] = RuntimeError("winrm down")
    assert make_service().call("catalog_get", {"id": "t.entry"}, actor="agent")["data"]["module_installed"] is None
    _gallery_entry(monkeypatch, "inbox:ActiveDirectory")
    out = make_service().call("catalog_get", {"id": "t.entry"}, actor="agent")
    assert out["data"]["module_installed"] is None


def _script(name):
    from sysadmin.runner import SCRIPTS_DIR

    return (SCRIPTS_DIR / f"{name}.ps1").read_text(encoding="utf-8")


def test_module_root_is_protected_before_any_write():
    prelude, install = _script("_prelude"), _script("catalog_module_install")
    assert "function Global:Assert-HermesModuleRoot" in prelude and "UnsafeModuleRoot:" in prelude
    assert "SetAccessRuleProtection($true, $false)" in prelude and "S-1-5-32-544" in prelude and "S-1-5-18" in prelude
    assert "Add-Type" not in prelude
    create = install.index("Assert-HermesModuleRoot -Create")
    for write in ("New-Item", "Invoke-WebRequest", "Copy-Item", "Move-Item", "Set-Content"):
        # the first write after the preview branch comes after the ACL gate
        assert install.index(write, install.index("LoadWithPartialName")) > create
    assert install.index("Assert-HermesModuleRoot\n", create) > create
    assert "Get-HermesModuleRootState" in _script("catalog_module_status") and "root_safe" in _script("catalog_module_status")
    use = prelude[prelude.index("function Global:Use-HermesModule"):]
    assert "Assert-HermesModuleRoot" in use and "-Create" not in use


def test_verification_is_by_file_hash_and_safer_staging():
    prelude, install = _script("_prelude"), _script("catalog_module_install")
    assert "Test-HermesModuleVerified" in _script("catalog_module_status") and "Test-HermesModuleVerified" in install
    assert "-Algorithm SHA256" in prelude and "files = $fileHashes" in install
    assert "-cne $m.package_hash" in install and ".part" in install and "$ProgressPreference = 'SilentlyContinue'" in install
    assert install.index("Copy-Item -LiteralPath $staged") < install.index("Get-FileHash -LiteralPath $work") < install.index("ExtractToDirectory($work")
    assert "Use staged package" in install and "dependency cycle" in install and "^\\d+(\\.\\d+){1,3}$" in install


def test_parent_reparse_and_ownership_checks():
    prelude, status, install = _script("_prelude"), _script("catalog_module_status"), _script("catalog_module_install")
    state = prelude[prelude.index("function Global:Get-HermesModuleRootState"):prelude.index("function Global:Assert-HermesModuleRoot")]
    assert "foreach ($p in @($base, $root))" in state and "ReparsePoint" in state and "Test-HermesTrustedOwner" in state
    assert "'foreign'" in state and "'broad'" in state and "'missing'" in state
    owner = prelude[prelude.index("function Global:Test-HermesTrustedOwner"):prelude.index("function Global:Get-HermesModuleRootState")]
    assert "GetOwner([System.Security.Principal.SecurityIdentifier])" in owner and "S-1-5-32-544" in owner and "S-1-5-18" in owner
    assert_ = prelude[prelude.index("function Global:Assert-HermesModuleRoot"):prelude.index("function Global:Get-HermesModuleRecord")]
    assert "foreach ($dir in @($base, $root))" in assert_ and "ReparsePoint" in assert_ and "Test-HermesTrustedOwner $dir" in assert_
    verified = prelude[prelude.index("function Global:Test-HermesModuleVerified"):prelude.index("function Global:Use-HermesModule")]
    assert "foreach ($owned in @($recordFile, $dir))" in verified and "Test-HermesTrustedOwner $owned" in verified
    assert "root_reason" in status and "$rootSafe = $null" in status and "-eq $true" in status
    assert "will be re-secured" in install and "fails the safety check" in install
    assert "will be re-secured" in install[install.index("'broad'"):install.index("'foreign'")]
    assert "fails the safety check" in install[install.index("'foreign'"):]


def test_install_tool_is_hidden_from_agents_while_the_lock_is_empty(synthetic_lock, monkeypatch):
    from sysadmin import tools

    seen = {}

    class Ctx:
        def register_tool(self, **kw):
            seen[kw["name"]] = kw.get("check_fn")

        def __getattr__(self, name):
            return lambda *a, **k: None

    tools.register_tools(Ctx())
    check = seen["catalog_module_install"]
    assert check() is True  # synthetic lock pins a module
    monkeypatch.setattr(modules, "LOCK_PATH", CATALOG_DIR / "modules.lock.json")
    assert check() is False
