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
    assert m["python_dependencies"] == ["pypsrp>=0.8.1,<0.9"]
    assert m["config_schema"]["password"] == {
        "type": "secret", "env": "SYSADMIN_WINRM_PASSWORD", "label": "Password",
        "description": "Password for the WinRM account. Stored in Hermes secrets, never in config.yaml.",
        "required": True,
    }
    assert m["config_schema"]["mode"]["choices"] == ["strict", "permissive", "read-only"]


def test_manifest_declares_exactly_what_register_registers():
    ctx = FakeCtx()
    load_plugin().register(ctx)
    m = manifest()
    assert sorted(m["provides_tools"]) == sorted(ctx.tools) == sorted(n for n in OPS if not n.startswith("t_"))
    assert sorted(m["provides_hooks"]) == sorted(ctx.hooks) == ["post_tool_call", "pre_tool_call"]
    assert m["provides_middleware"] == []
