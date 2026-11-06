"""Catalog entries: catalog/<area>/<name>.ps1 files with a YAML header, registered as cat.<id> Ops."""

from __future__ import annotations

import json
import logging
import re
from pathlib import Path
from typing import Any, Mapping

import yaml

from .policy import is_domain_controller_name
from .registry import OPS, Op, Param, register
from .runner import CATALOG_DIR

log = logging.getLogger(__name__)

CATEGORIES = (
    "Endpoint health", "Security posture", "Patching", "Users & sessions", "Remote access", "Network",
    "Printers", "AD hygiene", "Group Policy", "DNS & DHCP", "Certificates", "Event logs",
    "File permissions", "Maintenance",
)
FLEET_LIMIT = 10
_HEADER = re.compile(r"^\s*<#\s*hermes-catalog\s*\n(.*?)\n\s*#>", re.S)
_ID = re.compile(r"^[a-z0-9_]+\.[a-z0-9_]+$")
_MODULE = re.compile(r"^(inbox:[A-Za-z][\w.]*|gallery:[A-Za-z][\w.]*@\d+(\.\d+){1,3})$")
_TYPES = {"string", "integer", "boolean", "array"}
_PARAM_DECL = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*)")


class CatalogError(ValueError):
    pass


def _lock_names() -> set[str]:
    path = CATALOG_DIR / "modules.lock.json"
    if not path.is_file():
        return set()
    data = json.loads(path.read_text(encoding="utf-8"))
    return {f"{m['name']}@{m['version']}" for m in data.get("modules", [])}


def _param_block(text: str) -> str:
    body = _HEADER.sub("", text, count=1).lstrip()
    if not body.lower().startswith("param("):
        raise CatalogError("the script must start with a param() block after the header")
    depth = 0
    for i, ch in enumerate(body):
        depth += ch == "("
        depth -= ch == ")"
        if depth == 0 and ch == ")":
            return body[: i + 1]
    raise CatalogError("unterminated param() block")


def parse_entry(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    m = _HEADER.match(text)
    if not m:
        raise CatalogError(f"{path.name}: missing '<# hermes-catalog ... #>' header")
    try:
        meta = yaml.safe_load(m.group(1)) or {}
    except yaml.YAMLError as exc:
        raise CatalogError(f"{path.name}: bad YAML header: {exc}") from exc
    where = f"{path.parent.name}/{path.name}"
    expected_id = f"{path.parent.name}.{path.stem}"
    if meta.get("id") != expected_id or not _ID.match(str(meta.get("id"))):
        raise CatalogError(f"{where}: id must be {expected_id!r}")
    for key in ("title", "category", "description", "module", "target", "tier"):
        if not meta.get(key):
            raise CatalogError(f"{where}: missing {key}")
    if meta["category"] not in CATEGORIES:
        raise CatalogError(f"{where}: unknown category {meta['category']!r}")
    if not _MODULE.match(str(meta["module"])):
        raise CatalogError(f"{where}: module must be inbox:<Module> or gallery:<Name>@<version>")
    if str(meta["module"]).startswith("gallery:") and meta["module"][len("gallery:"):] not in _lock_names():
        raise CatalogError(f"{where}: {meta['module']} is not pinned in catalog/modules.lock.json")
    if meta["target"] not in ("dc", "endpoint"):
        raise CatalogError(f"{where}: target must be dc or endpoint")
    if meta["tier"] not in ("R", "W", "H"):
        raise CatalogError(f"{where}: tier must be R, W or H")
    meta.setdefault("preview", "none")
    meta.setdefault("destructive", False)
    meta.setdefault("columns", [])
    meta.setdefault("tags", [])
    meta.setdefault("params", [])
    meta.setdefault("source", "")
    if meta["preview"] not in ("none", "plan"):
        raise CatalogError(f"{where}: preview must be none or plan")
    if meta["tier"] == "R" and meta["preview"] != "none":
        raise CatalogError(f"{where}: read entries have no preview")
    if meta["tier"] in ("W", "H") and meta["preview"] != "plan":
        raise CatalogError(f"{where}: write entries need preview: plan")
    if meta["destructive"] and meta["tier"] != "H":
        raise CatalogError(f"{where}: destructive entries must be tier H")
    declared = {n.lower() for n in _PARAM_DECL.findall(_param_block(text))}
    for p in meta["params"]:
        if not isinstance(p, dict) or not p.get("name") or p.get("type") not in _TYPES:
            raise CatalogError(f"{where}: each param needs a name and a type in {sorted(_TYPES)}")
        if p["name"].lower() not in declared:
            raise CatalogError(f"{where}: param {p['name']} is not declared in param()")
    if meta["target"] == "endpoint" and not {"computers", "ou"} <= declared:
        raise CatalogError(f"{where}: endpoint entries must declare $Computers and $Ou")
    if meta["preview"] == "plan" and "preview" not in declared:
        raise CatalogError(f"{where}: plan entries must declare [switch]$Preview")
    meta["_rel"] = where
    return meta


def _fleet_escalate(args: Mapping[str, Any], settings: Any, facts: Any) -> bool:
    computers = [c for c in (args.get("computers") or []) if c]
    if args.get("ou") or not computers or len(computers) > FLEET_LIMIT:
        return True
    dcs = facts.domain_controllers() if facts is not None else None
    if not dcs:
        return True  # unknown DC list: fail closed
    return any(is_domain_controller_name(c, dcs) for c in computers)


def _to_op(meta: dict[str, Any]) -> Op:
    params = [
        Param(
            p["name"], p["type"], str(p.get("description") or p["name"]),
            required=bool(p.get("required")), ps=p["name"],
            enum=tuple(p["enum"]) if p.get("enum") else None,
            default=p.get("default"), minimum=p.get("minimum"),
        )
        for p in meta["params"]
    ]
    if meta["target"] == "endpoint":
        params += [
            Param("computers", "array", "Computer names. Omit for every enabled workstation (high-risk for writes).", ps="Computers"),
            Param("ou", "string", "DN of an OU whose enabled computers to include.", ps="Ou"),
        ]
    is_fleet_write = meta["target"] == "endpoint" and meta["tier"] == "W"
    return Op(
        name=f"cat.{meta['id']}", toolset="catalog", tier=meta["tier"], script=f"catalog:{meta['_rel']}",
        description=str(meta["description"]).strip(), params=tuple(params),
        preview=meta["preview"] == "plan", destructive=bool(meta["destructive"]),
        escalate=_fleet_escalate if is_fleet_write else None, catalog=True,
        target=(lambda a: ", ".join(a.get("computers") or []) or a.get("ou") or "all workstations")
        if meta["target"] == "endpoint" else None,
        meta={k: meta[k] for k in ("id", "title", "category", "module", "target", "columns", "tags", "source", "preview")},
    )


def load(directory: Path = CATALOG_DIR, *, strict: bool = False) -> list[Op]:
    out: list[Op] = []
    for path in sorted(directory.glob("*/*.ps1")):
        try:
            op = _to_op(parse_entry(path))
            if op.name in OPS:
                if strict:
                    raise CatalogError(f"duplicate catalog id {op.meta['id']}")
                continue  # already registered (the package loads the shipped catalog at import)
            out.append(register(op))
        except Exception as exc:
            if strict:
                raise CatalogError(str(exc)) from exc
            log.error("hermes-sysadmin: skipped catalog entry %s: %s", path, exc)
    return out


def entries() -> list[Op]:
    return sorted((op for op in OPS.values() if op.catalog), key=lambda o: o.name)
