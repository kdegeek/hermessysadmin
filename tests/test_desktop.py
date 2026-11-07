"""Static checks for the Hermes Desktop page in desktop/plugin.js.

The desktop runtime loads one ESM file with no build step, so these tests enforce its
rules: imports only from the three host modules, no JSX, no DOM/global escapes, colours
only through the app's --ui-* tokens, and every op the page calls exists in the registry.
"""
from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

import sysadmin.ops  # noqa: F401  (importing the package registers every op)
from sysadmin.registry import OPS

PLUGIN = Path(__file__).resolve().parents[1] / "desktop" / "plugin.js"
ALLOWED_IMPORTS = {"react", "react/jsx-runtime", "@hermes/plugin-sdk"}
FORBIDDEN = ["eval(", "new Function", "document.", "window.", "localStorage", "sessionStorage", "import(", "require(", "innerHTML"]
REST_PATHS = {"/health", "/test-connection", "/overview", "/audit", "/refresh", "/ops/", "/catalog", "/fleet", "/fleet/history", "/fleet/", "/monitoring", "/remote/sessions", "/remote/"}


@pytest.fixture(scope="module")
def code() -> str:
    """plugin.js without full-line // comments (comments may mention forbidden words)."""
    lines = PLUGIN.read_text(encoding="utf-8").splitlines()
    return "\n".join(line for line in lines if not line.lstrip().startswith("//"))


def test_default_export_and_plugin_id(code):
    assert "export default {" in code
    assert "const PLUGIN_ID = 'hermes-sysadmin';" in code


def test_imports_only_from_allowed_modules(code):
    modules = re.findall(r"^\s*import\b[^;]*?\bfrom\s+'([^']+)'", code, re.M | re.S)
    bare = re.findall(r"^\s*import\s+'([^']+)'", code, re.M)
    assert set(modules) | set(bare) <= ALLOWED_IMPORTS
    assert {"react/jsx-runtime", "@hermes/plugin-sdk"} <= set(modules)


@pytest.mark.parametrize("token", FORBIDDEN)
def test_forbidden_token_absent(code, token):
    assert token not in code


def test_no_jsx_syntax(code):
    # A JSX tag starts after an operator, a bracket or `return`; comparisons (`a < b`) do not.
    hits = re.findall(r"(?:^|[=(,:?&|{\[]\s*|\breturn\s+)<\s*/?[A-Za-z][\w.]*", code, re.M)
    assert hits == []


def test_colours_only_through_ui_tokens(code):
    without_tokens = re.sub(r"var\(--ui-[\w-]+(?:\s*,\s*[^()]*(?:\([^()]*\))?[^()]*)?\)", "var()", code)
    assert re.findall(r"#[0-9a-fA-F]{3,8}\b", without_tokens) == []
    assert re.findall(r"\b(?:rgba?|hsla?)\(", without_tokens) == []


def test_css_variables_are_ui_tokens(code):
    names = re.findall(r"var\(--([\w-]+)", code)
    assert names and all(name.startswith(("ui-", "hs-series-")) for name in names)  # hs-series-N are chart aliases of --ui-* tokens


def test_op_helper_is_defined(code):
    assert "function op(name, args) {" in code


def test_every_op_name_is_registered(code):
    names = set(re.findall(r"(?<![\w.$])op\(\s*'([a-z0-9_]+)'", code))
    assert sorted(n for n in names if n not in OPS) == []
    assert sorted(n for n in names if n.startswith("t_")) == []


def test_op_calls_use_literal_names(code):
    for m in re.finditer(r"(?<![\w.$])op\((\s*)(\S)", code):
        if code[: m.start()].endswith("function "):
            continue
        head = code[m.start(): m.start() + 60]
        # Catalog runs use a template literal (op(`cat.${id}`, ...)); every other op name is a plain literal.
        assert m.group(2) == "'" or re.match(r"op\(\s*`cat\.\$\{", head), head


def test_ops_routes_only_built_from_op_name(code):
    tails = re.findall(r"/ops/(.{9})", code)
    assert tails and all(t == "${o.name}" for t in tails)


def test_rest_paths_are_backend_routes(code):
    paths = set(re.findall(r"\brest\(\s*[`']([^`'?$]+)", code))
    assert paths and paths <= REST_PATHS


def test_subscribes_to_change_event(code):
    assert "const CHANGED_EVENT = 'plugin.hermes-sysadmin.changed';" in code
    handler = code[code.index("ctx.onEvent(CHANGED_EVENT"):][:200]
    assert handler.index("api.refresh()") < handler.index("invalidateAll()")
    assert "(-Preview)" in code and "(-WhatIf)" not in code


def test_node_syntax_check(tmp_path):
    node = shutil.which("node")
    if node is None:
        pytest.skip("node is not installed")
    copy = tmp_path / "plugin.mjs"  # .mjs: parse as ESM on every node version
    copy.write_text(PLUGIN.read_text(encoding="utf-8"), encoding="utf-8")
    out = subprocess.run([node, "--check", str(copy)], capture_output=True, text=True)
    assert out.returncode == 0, out.stderr


@pytest.mark.parametrize("needle", [
    "'monitoring_enable'", "'monitoring_disable'", "function Donut(", "function Sparkline(", "goTab('fleet'",
])
def test_overview_rebuild_markers(code, needle):
    assert needle in code


@pytest.mark.parametrize("needle", [
    "function FleetTab(", "function DeviceDrawer(", "function openDevice(", "'remote_shadow_command'", "key: 'fleet'",
    "function openCatalogRun(", "$fleetSelection",
])
def test_fleet_tab_markers(code, needle):
    assert needle in code
