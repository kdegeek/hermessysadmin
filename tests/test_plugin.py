import importlib.util
import sys
from pathlib import Path

import yaml

from sysadmin import ops  # noqa: F401
from sysadmin.registry import OPS

ROOT = Path(__file__).resolve().parent.parent


def load_plugin():
    name = "hermes_sysadmin_plugin_under_test"
    spec = importlib.util.spec_from_file_location(name, ROOT / "__init__.py", submodule_search_locations=[str(ROOT)])
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class FakeCtx:
    def __init__(self):
        self.tools, self.hooks, self.skills, self.commands = {}, {}, {}, {}

    def register_tool(self, **kwargs):
        self.tools[kwargs["name"]] = kwargs

    def register_hook(self, name, fn, **kwargs):
        self.hooks[name] = fn

    def register_skill(self, name, path, **kwargs):
        self.skills[name] = Path(path)

    def register_command(self, name, handler, description="", args_hint="", **kwargs):
        self.commands[name] = (handler, description, args_hint)

    def ask_choice(self, question, choices):
        return choices[0]


def manifest():
    return yaml.safe_load((ROOT / "plugin.yaml").read_text(encoding="utf-8"))


def test_manifest_core_fields():
    m = manifest()
    assert m["name"] == "hermes-sysadmin"
    assert m["manifest_version"] == 2
    assert m["requires_hermes"] == ">=0.22.2"
    assert m["python_dependencies"] == ["pypsrp>=0.8.1,<0.9", "pyyaml>=6.0,<7"]
    assert m["config_schema"]["password"] == {
        "type": "secret", "env": "SYSADMIN_WINRM_PASSWORD", "label": "Password",
        "description": "Password for the account. Stored in Hermes secrets, never in config.yaml.",
    }
    schema = m["config_schema"]
    assert list(schema)[:2] == ["transport", "run_as"]
    assert schema["transport"]["choices"] == ["auto", "local", "winrm"] and schema["transport"]["default"] == "auto"
    assert schema["run_as"]["choices"] == ["account", "hermes_user"] and schema["run_as"]["default"] == "account"
    assert schema["host"]["label"] == "Jump host (WinRM transport only)"
    # Which of host/username/password is needed depends on the transport, so none is schema-required.
    assert not any(schema[k].get("required") for k in ("host", "username", "password"))
    assert m["config_schema"]["mode"]["choices"] == ["strict", "permissive", "read-only"]


def test_manifest_declares_exactly_what_register_registers():
    ctx = FakeCtx()
    load_plugin().register(ctx)
    m = manifest()
    assert sorted(m["provides_tools"]) == sorted(ctx.tools) == sorted([n for n in OPS if not n.startswith("t_") and not OPS[n].catalog] + ["catalog_run"])
    assert sorted(m["provides_hooks"]) == sorted(ctx.hooks) == ["post_tool_call", "pre_tool_call"]
    assert "provides_middleware" not in m and m["kind"] == "standalone"


import re

from sysadmin.tools import EMOJI

SKILL_NAMES = {
    "onboard-user", "offboard-user", "lockout-triage", "gpo-change",
    "domain-health-check", "access-review", "backup-recovery-guide",
    "fleet-health-check", "endpoint-triage", "remote-assist",
}
TOOL_WORD = re.compile(r"(?<![.\w])(?:ad|gpo|rdp|backup|sysadmin|fleet|remote|catalog|monitoring)_[a-z_]+\b")


def _frontmatter(text):
    assert text.startswith("---\n"), "SKILL.md must start with YAML frontmatter"
    head, body = text[4:].split("\n---\n", 1)
    return yaml.safe_load(head), body


def test_register_adds_skills_and_ad_command():
    ctx = FakeCtx()
    load_plugin().register(ctx)
    assert set(ctx.skills) == SKILL_NAMES
    assert all(p.is_file() and p.name == "SKILL.md" for p in ctx.skills.values())
    handler, description, args_hint = ctx.commands["ad"]
    assert callable(handler) and "status" in args_hint


def test_register_hooks_are_the_real_gate_functions():
    ctx = FakeCtx()
    plugin = load_plugin()
    plugin.register(ctx)
    # The plugin imports sysadmin as a submodule of itself, not as top-level "sysadmin".
    hooks = sys.modules[plugin.__name__ + ".sysadmin.hooks"]
    assert ctx.hooks["pre_tool_call"] is hooks.pre_tool_call
    assert ctx.hooks["post_tool_call"] is hooks.post_tool_call


def test_skills_are_well_formed_and_only_name_real_tools():
    known = set(OPS) | set(EMOJI) | set(manifest()["provides_tools"])
    for name in SKILL_NAMES:
        meta, body = _frontmatter((ROOT / "skills" / name / "SKILL.md").read_text(encoding="utf-8"))
        assert meta["name"] == name
        assert 20 <= len(meta["description"]) <= 1024
        unknown = sorted(set(TOOL_WORD.findall(body)) - known)
        assert not unknown, f"{name} mentions unknown tools: {unknown}"


CATALOG_ID = re.compile(r"`((?:ad|certs|dhcp|dns|endpoint|events|files|gpo|maint|network|patch|printers|remote|security|sessions)\.[a-z0-9_]+)`")


def test_skills_only_name_real_catalog_entries():
    from sysadmin import catalog

    real = {op.meta["id"] for op in catalog.entries()}
    for name in SKILL_NAMES:
        body = (ROOT / "skills" / name / "SKILL.md").read_text(encoding="utf-8")
        assert not set(CATALOG_ID.findall(body)) - real, f"{name} names unknown catalog ids"


def test_catalog_helper_lines_in_existing_skills():
    for name in ("domain-health-check", "lockout-triage", "access-review", "gpo-change"):
        body = (ROOT / "skills" / name / "SKILL.md").read_text(encoding="utf-8")
        assert "Catalog entries that help" in body, name


def test_version_is_0_2_0():
    import sysadmin

    assert sysadmin.__version__ == "0.2.2" and manifest()["version"] == "0.2.2"
