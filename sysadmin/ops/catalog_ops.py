"""Agent-facing catalog discovery: search and inspect vetted catalog entries (read-only, local)."""

from __future__ import annotations

import re
from typing import Any, Mapping

from .. import catalog
from ..errors import InvalidArguments
from ..registry import Op, Param, register

TOOLSET = "catalog"


def _summary(op: Op) -> dict[str, Any]:
    m = op.meta or {}
    return {
        "id": m.get("id"), "title": m.get("title"), "category": m.get("category"), "target": m.get("target"),
        "tier": op.tier, "module": m.get("module"), "params": [p.name for p in op.params],
        "description": op.description,
    }


def _score(op: Op, tokens: list[str]) -> int:
    m = op.meta or {}
    id_, title = str(m.get("id", "")).lower(), str(m.get("title", "")).lower()
    tags = " ".join(str(t) for t in m.get("tags") or []).lower()
    desc = op.description.lower()
    return sum(3 * (t in id_) + 3 * (t in title) + 2 * (t in tags) + (t in desc) for t in tokens)


def _search(service: Any, args: Mapping[str, Any]) -> Any:
    tokens = re.findall(r"[a-z0-9_.]+", str(args.get("query") or "").lower())
    cat, target, tier = args.get("category"), args.get("target"), args.get("tier")
    rows: list[tuple[int, Op]] = []
    for op in catalog.entries():
        m = op.meta or {}
        if (cat and m.get("category") != cat) or (target and m.get("target") != target) or (tier and op.tier != tier):
            continue
        score = _score(op, tokens)
        if tokens and score == 0:
            continue
        rows.append((score, op))
    if tokens:
        rows.sort(key=lambda r: (-r[0], r[1].meta["id"]))
    else:
        rows.sort(key=lambda r: (r[1].meta["category"], r[1].meta["id"]))
    limit = int(args.get("limit") or 20)
    return {"items": [_summary(op) for _, op in rows[:limit]], "total": len(rows)}


def entry_detail(op: Op) -> dict[str, Any]:
    """catalog_get-shaped dict without the example (shared with the dashboard API)."""
    params = [
        {"name": p.name, "type": p.type, "description": p.description, "required": p.required,
         "default": p.default, "enum": list(p.enum) if p.enum else None, "minimum": p.minimum}
        for p in op.params
    ]
    return {**(op.meta or {}), "tier": op.tier, "destructive": op.destructive, "description": op.description,
            "params": params, "module_installed": None}


def _module_installed(service: Any, module: str) -> bool | None:
    """True/false for a gallery:<name>@<version> entry from a (cached) status call; None when unknown."""
    if not module.startswith("gallery:"):
        return None
    name, _, version = module[len("gallery:"):].partition("@")
    try:
        data = service._run_cached(service._op("catalog_module_status"), {})
        for row in (data or {}).get("items", []):
            if row.get("name") == name and row.get("version") == version:
                return bool(row.get("installed"))
    except Exception:
        return None
    return None


def _get(service: Any, args: Mapping[str, Any]) -> Any:
    entry_id = str(args.get("id") or "")
    op = next((o for o in catalog.entries() if (o.meta or {}).get("id") == entry_id), None)
    if op is None:
        raise InvalidArguments(f"Unknown catalog entry '{entry_id}'. Use catalog_search to find ids.")
    detail = entry_detail(op)
    detail["module_installed"] = _module_installed(service, str((op.meta or {}).get("module") or ""))
    example: dict[str, Any] = {
        "id": entry_id,
        "params": {p.name: p.default for p in op.params if p.default is not None and p.name not in ("computers", "ou")},
    }
    if (op.meta or {}).get("target") == "endpoint":
        example["computers"] = ["PC-NAME"]
    return {**detail, "example": example}


register(Op(
    name="catalog_search", toolset=TOOLSET, tier="R", script="",
    description=(
        "Search the vetted catalog of PowerShell tasks (disk usage, uptime, patches, ...) by keyword, category, "
        "target or tier. Returns ids to pass to catalog_get and catalog_run."
    ),
    params=(
        Param("query", "string", "Keywords; empty lists everything."),
        Param("category", "string", "Only this category.", enum=catalog.CATEGORIES),
        Param("target", "string", "Where entries run.", enum=("dc", "endpoint")),
        Param("tier", "string", "Only this risk tier.", enum=("R", "W", "H")),
        Param("limit", "integer", "Maximum entries to return.", default=20, minimum=1),
    ),
    local=_search,
))

register(Op(
    name="catalog_get", toolset=TOOLSET, tier="R", script="",
    description="Show one catalog entry: tier, parameters, columns and a ready-to-edit catalog_run example.",
    params=(Param("id", "string", "Catalog id, e.g. endpoint.uptime.", required=True),),
    local=_get,
))
