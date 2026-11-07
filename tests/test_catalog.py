# tests/test_catalog.py
import textwrap
from pathlib import Path

import pytest

from sysadmin import catalog
from sysadmin.config import Settings
from sysadmin.policy import NoFacts, decide
from sysadmin.registry import OPS
from sysadmin.runner import Runner

ENTRY = textwrap.dedent("""\
    <# hermes-catalog
    id: t_area.sample
    title: Sample
    category: Endpoint health
    description: A sample entry.
    module: inbox:Storage
    target: endpoint
    tier: W
    destructive: false
    preview: plan
    columns: [host, value]
    tags: [sample]
    source: In-box
    params:
      - {name: Threshold, type: integer, default: 10, minimum: 1, description: A threshold.}
    #>
    param([string[]]$Computers = @(), [string]$Ou, [int]$Threshold = 10, [switch]$Preview)
    Invoke-Op {
        @{ ok = $true }
    }
    """)


def write(tmp_path: Path, rel: str, text: str) -> Path:
    p = tmp_path / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding="utf-8")
    return p


@pytest.fixture
def cleanup():
    yield
    for name in [n for n in OPS if n.startswith("cat.t_area.")]:
        OPS.pop(name)


def test_parse_and_register_endpoint_entry(tmp_path, cleanup):
    write(tmp_path, "t_area/sample.ps1", ENTRY)
    (op,) = catalog.load(tmp_path, strict=True)
    assert op.name == "cat.t_area.sample" and op.catalog and op.tier == "W" and op.preview
    assert op.script == "catalog:t_area/sample.ps1"
    assert [p.name for p in op.params] == ["Threshold", "computers", "ou"]
    assert op.meta["category"] == "Endpoint health" and op.meta["columns"] == ["host", "value"]


@pytest.mark.parametrize("bad, fragment", [
    ("id: t_area.sample", "id: other.sample"),                 # id must match <dir>.<file stem>
    ("category: Endpoint health", "category: Nope"),           # unknown category
    ("module: inbox:Storage", "module: gallery:Nope@1.0"),     # not in the lock file
    ("preview: plan", "preview: none"),                        # W entries need a plan preview
    ("{name: Threshold,", "{name: Missing,"),                  # header param not declared in param()
])
def test_invalid_entries_raise_in_strict_mode(tmp_path, cleanup, bad, fragment):
    write(tmp_path, "t_area/sample.ps1", ENTRY.replace(bad, fragment))
    with pytest.raises(catalog.CatalogError):
        catalog.load(tmp_path, strict=True)


def test_invalid_entry_is_skipped_when_not_strict(tmp_path, cleanup):
    write(tmp_path, "t_area/sample.ps1", ENTRY.replace("tier: W", "tier: X"))
    assert catalog.load(tmp_path) == []


def test_fleet_escalation(tmp_path, cleanup):
    write(tmp_path, "t_area/sample.ps1", ENTRY)
    (op,) = catalog.load(tmp_path, strict=True)
    s = Settings(host="dc01", username="u", password="p")

    class Facts:
        def domain_controllers(self):
            return ["DC01", "DC02"]

    def tier(args, facts=Facts()):
        return decide(op, args, s, facts).tier

    assert tier({"computers": ["PC1", "PC2"]}) == "W"
    assert tier({"computers": [f"PC{i}" for i in range(11)]}) == "H"
    assert tier({"ou": "OU=x,DC=corp"}) == "H"
    assert tier({}) == "H"                                    # fallback to all
    assert tier({"computers": ["dc02.corp.example"]}) == "H"
    assert tier({"computers": ["PC1"]}, NoFacts()) == "H"     # unknown DCs fail closed


def test_runner_loads_catalog_paths_only_inside_catalog_dir(tmp_path):
    r = Runner(transport=None)
    with pytest.raises(Exception):
        r.load_script("catalog:../sysadmin/scripts/_prelude.ps1")
    assert "Invoke-Op" in r.load_script("catalog:endpoint/disk_usage.ps1")


def test_shipped_catalog_is_valid():
    ops = catalog.load(catalog.CATALOG_DIR, strict=True) if not catalog.entries() else catalog.entries()
    ids = [o.meta["id"] for o in ops]
    assert len(ids) == len(set(ids)) and "endpoint.disk_usage" in ids


def test_catalog_ops_are_not_agent_tools():
    from sysadmin import tools

    class Ctx:
        def __init__(self):
            self.names = []

        def register_tool(self, name, **kw):
            self.names.append(name)

    ctx = Ctx()
    tools.register_tools(ctx)
    assert not [n for n in ctx.names if n.startswith("cat.")]


def test_maximum_flows_into_schema_and_coercion(tmp_path, cleanup):
    from sysadmin.errors import InvalidArguments
    from sysadmin.registry import coerce_args, schema_for

    text = ENTRY.replace(
        "{name: Threshold, type: integer, default: 10, minimum: 1, description: A threshold.}",
        "{name: Level, type: integer, minimum: 0, maximum: 4, default: 2, description: x}",
    ).replace("[int]$Threshold = 10", "[int]$Level = 2")
    write(tmp_path, "t_area/sample.ps1", text)
    (op,) = catalog.load(tmp_path, strict=True)
    schema = schema_for(op)
    props = schema.get("properties") or schema["parameters"]["properties"]
    assert props["Level"]["minimum"] == 0 and props["Level"]["maximum"] == 4
    assert coerce_args(op, {"Level": 4})["Level"] == 4
    with pytest.raises(InvalidArguments):
        coerce_args(op, {"Level": 5})


def test_entry_detail_includes_maximum(tmp_path, cleanup):
    from sysadmin.ops.catalog_ops import entry_detail

    text = ENTRY.replace(
        "{name: Threshold, type: integer, default: 10, minimum: 1, description: A threshold.}",
        "{name: Level, type: integer, minimum: 0, maximum: 4, default: 2, description: x}",
    ).replace("[int]$Threshold = 10", "[int]$Level = 2")
    write(tmp_path, "t_area/sample.ps1", text)
    (op,) = catalog.load(tmp_path, strict=True)
    level = next(p for p in entry_detail(op)["params"] if p["name"] == "Level")
    assert (level["minimum"], level["maximum"]) == (0, 4)


@pytest.mark.parametrize("param", [
    "{name: Threshold, type: integer, description: x, enum: []}",
    "{name: Threshold, type: integer, description: x, enum: abc}",
    "{name: Threshold, type: integer, description: x, minimum: abc}",
    "{name: Threshold, type: integer, description: x, maximum: true}",
    "{name: Threshold, type: string, description: x, minimum: 1}",
    "{name: Threshold, type: string, description: x, maximum: 1}",
    "{name: Threshold, type: integer, description: x, minimum: 5, maximum: 2}",
    "{name: Threshold, type: integer, description: x, minimum: 5, default: 1}",
    "{name: Threshold, type: integer, description: x, maximum: 5, default: 9}",
    "{name: Threshold, type: string, description: x, enum: [a, b], default: c}",
    "{name: Threshold, type: integer}",
    "{name: Threshold, type: integer, description: ''}",
])
def test_invalid_param_headers_raise(tmp_path, cleanup, param):
    old = "{name: Threshold, type: integer, default: 10, minimum: 1, description: A threshold.}"
    write(tmp_path, "t_area/sample.ps1", ENTRY.replace(old, param))
    with pytest.raises(catalog.CatalogError):
        catalog.load(tmp_path, strict=True)


def _with_when(when):
    return ENTRY.replace("params:\n", f"escalate_when: {when}\nparams:\n")


def test_escalate_when_raises_tier_for_matching_param_values(tmp_path, cleanup):
    write(tmp_path, "t_area/sample.ps1", _with_when("{Threshold: [2, 4]}"))
    (op,) = catalog.load(tmp_path, strict=True)

    class Facts:
        def domain_controllers(self):
            return ["DC01"]

    def tier(args):
        return decide(op, {"computers": ["PC1"], **args}, Settings(host="dc01", username="u", password="p"), Facts()).tier

    assert tier({}) == "W" and tier({"Threshold": 1}) == "W" and tier({"Threshold": 3}) == "W"
    assert tier({"Threshold": 2}) == "H" and tier({"Threshold": 4}) == "H"
    assert decide(op, {"computers": ["10.0.0.1"], "Threshold": 1}, Settings(host="dc01", username="u", password="p"), Facts()).tier == "H"


@pytest.mark.parametrize("when", ["{Nope: [1]}", "{Threshold: 2}", "{Threshold: []}", "[Threshold]"])
def test_escalate_when_is_validated(tmp_path, cleanup, when):
    write(tmp_path, "t_area/sample.ps1", _with_when(when))
    with pytest.raises(catalog.CatalogError):
        catalog.load(tmp_path, strict=True)


def test_shipped_shadow_policy_defaults_to_consent_and_escalates_no_consent_levels():
    from sysadmin.catalog import parse_entry, CATALOG_DIR
    meta = parse_entry(CATALOG_DIR / "remote" / "set_shadow_policy.ps1")
    (level,) = [p for p in meta["params"] if p["name"] == "Level"]
    assert level["default"] == 1 and "[int]$Level = 1" in (CATALOG_DIR / "remote" / "set_shadow_policy.ps1").read_text()
    op = OPS["cat.remote.set_shadow_policy"]

    class Facts:
        def domain_controllers(self):
            return ["DC01"]

    s = Settings(host="dc01", username="u", password="p")
    tiers = {lv: decide(op, {"computers": ["PC1"], "Level": lv}, s, Facts()).tier for lv in range(5)}
    assert tiers == {0: "W", 1: "W", 2: "H", 3: "W", 4: "H"}
