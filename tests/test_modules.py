import json
from dataclasses import replace

from sysadmin import catalog
from sysadmin.catalog import CATALOG_DIR
from sysadmin.registry import OPS


def lock():
    return json.loads((CATALOG_DIR / "modules.lock.json").read_text(encoding="utf-8"))


def test_lock_pins_exact_versions_with_sha512():
    mods = {m["name"]: m for m in lock()["modules"]}
    assert mods["PSWindowsUpdate"]["version"] == "2.2.1.5"
    assert mods["GPOZaurr"]["version"] == "1.1.13" and mods["ADEssentials"]["version"] == "1.0.7"
    for m in mods.values():
        assert m["hash_algorithm"] == "SHA512" and len(m["package_hash"]) == 88  # base64 of 64 bytes
        assert all(r in mods for r in m["requires"])


def test_lock_dependency_closure_and_signers():
    mods = {m["name"]: m for m in lock()["modules"]}
    assert set(mods) == {"PSWindowsUpdate", "ADEssentials", "PSEventViewer", "PSWriteHTML", "PSSharedGoods", "GPOZaurr", "NTFSSecurity"}
    assert set(mods["ADEssentials"]["requires"]) == {"PSEventViewer", "PSWriteHTML"}
    assert set(mods["GPOZaurr"]["requires"]) == {"ADEssentials", "PSEventViewer", "PSWriteHTML"}
    for name in ("ADEssentials", "PSEventViewer", "PSWriteHTML", "PSSharedGoods", "GPOZaurr"):
        assert mods[name]["signer"] == "Evotec Services sp. z o.o."
    assert mods["PSWindowsUpdate"]["signer"] is None and mods["NTFSSecurity"]["signer"] is None


def test_install_is_high_risk_with_preview_and_enum():
    op = OPS["catalog_module_install"]
    assert op.tier == "H" and op.preview
    assert set(op.params[0].enum) == {m["name"] for m in lock()["modules"]}


def test_install_preview_injects_lock(make_service, runner):
    runner.responses["catalog_module_install"] = {"summary": "s", "changes": [], "current": {}}
    make_service().preview("catalog_module_install", {"name": "NTFSSecurity"})
    _, params, _ = runner.calls[-1]
    assert json.loads(params["Lock"])["modules"] and params["Preview"] is True


def test_status_is_a_cached_read_that_injects_the_lock(make_service, runner):
    status = {"root": "C:\\ProgramData\\HermesSysadmin\\Modules", "items": []}
    runner.responses["catalog_module_status"] = status
    svc = make_service()
    assert OPS["catalog_module_status"].tier == "R" and OPS["catalog_module_status"].params == ()
    assert svc.call("catalog_module_status", {}, actor="agent")["data"] == status
    svc.call("catalog_module_status", {}, actor="agent")
    assert len(runner.calls) == 1 and json.loads(runner.calls[0][1]["Lock"])["modules"]


def _gallery_entry(monkeypatch, module):
    base = OPS["catalog_get"]
    op = replace(base, name="cat.t", meta={"id": "t.entry", "title": "T", "category": "ad", "target": "dc", "module": module})
    monkeypatch.setattr(catalog, "entries", lambda: [op])


def test_catalog_get_reports_module_installed(monkeypatch, make_service, runner):
    _gallery_entry(monkeypatch, "gallery:GPOZaurr@1.1.13")
    runner.responses["catalog_module_status"] = {"root": "r", "items": [
        {"name": "GPOZaurr", "version": "1.1.13", "installed": True, "verified": True, "signer_ok": True}]}
    out = make_service().call("catalog_get", {"id": "t.entry"}, actor="agent")
    assert out["data"]["module_installed"] is True
    runner.responses["catalog_module_status"] = {"root": "r", "items": [
        {"name": "GPOZaurr", "version": "1.1.13", "installed": False, "verified": False, "signer_ok": None}]}
    assert make_service().call("catalog_get", {"id": "t.entry"}, actor="agent")["data"]["module_installed"] is False


def test_catalog_get_module_installed_is_null_on_error_or_inbox(monkeypatch, make_service, runner):
    _gallery_entry(monkeypatch, "gallery:GPOZaurr@1.1.13")
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
    assert "Assert-HermesModuleRoot" in _script("catalog_module_status") and "root_safe" in _script("catalog_module_status")
    use = prelude[prelude.index("function Global:Use-HermesModule"):]
    assert "Assert-HermesModuleRoot" in use and "-Create" not in use


def test_verification_is_by_file_hash_and_safer_staging():
    prelude, install = _script("_prelude"), _script("catalog_module_install")
    assert "Test-HermesModuleVerified" in _script("catalog_module_status") and "Test-HermesModuleVerified" in install
    assert "-Algorithm SHA256" in prelude and "files = $fileHashes" in install
    assert "-cne $m.package_hash" in install and ".part" in install and "$ProgressPreference = 'SilentlyContinue'" in install
    assert install.index("Copy-Item -LiteralPath $staged") < install.index("Get-FileHash -LiteralPath $work") < install.index("ExtractToDirectory($work")
    assert "Use staged package" in install and "dependency cycle" in install and "^\\d+(\\.\\d+){1,3}$" in install
