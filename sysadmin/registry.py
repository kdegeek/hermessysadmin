"""Declarative operation registry. One Op == one agent tool == one PowerShell script."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any, Callable, Mapping

from .errors import InvalidArguments

_INT_RE = re.compile(r"-?[0-9]+")

TIERS = ("R", "W", "H")
TIER_LABEL = {"R": "read-only", "W": "write · needs approval", "H": "high-risk · needs approval"}


@dataclass(frozen=True)
class Param:
    name: str
    type: str  # "string" | "integer" | "boolean" | "array"
    description: str
    required: bool = False
    ps: str | None = None
    enum: tuple[str, ...] | None = None
    default: Any = None
    items: str = "string"
    minimum: int | None = None

    @property
    def ps_name(self) -> str:
        return self.ps or "".join(part.capitalize() for part in self.name.split("_"))


@dataclass(frozen=True)
class Op:
    name: str
    toolset: str
    tier: str
    script: str
    description: str
    params: tuple[Param, ...] = ()
    target: Callable[[Mapping[str, Any]], str] | None = None
    identities: tuple[str, ...] = ()
    escalate: Callable[[Mapping[str, Any], Any, Any], bool] | None = None
    preview: bool = False
    post: Callable[[Any, Mapping[str, Any], Any], Any] | None = None
    cache_ttl: float = 0.0
    inject: Callable[[Any], Mapping[str, Any]] | None = None  # extra PS params derived from Settings
    local: Callable[[Any, Mapping[str, Any]], Any] | None = None  # run in Python as local(service, args) instead of a script
    enabled: Callable[[Any], bool] | None = None  # enabled(settings) False -> decide() blocks the op
    destructive: bool = False  # irreversible (delete/overwrite/arbitrary code): dashboard requires typing the name
    catalog: bool = False  # a cat.<id> entry from catalog/; reachable through catalog_run, not its own agent tool
    meta: Mapping[str, Any] | None = None  # catalog metadata for search and the UI


OPS: dict[str, Op] = {}


def register(op: Op) -> Op:
    if op.tier not in TIERS:
        raise ValueError(f"{op.name}: tier must be one of {TIERS}")
    if op.name in OPS:
        raise ValueError(f"duplicate op {op.name}")
    if op.preview and op.tier == "R":
        raise ValueError(f"{op.name}: read ops cannot preview")
    names = [p.name for p in op.params]
    if len(set(names)) != len(names):
        raise ValueError(f"{op.name}: duplicate parameter names")
    OPS[op.name] = op
    return op


def schema_for(op: Op) -> dict[str, Any]:
    props: dict[str, Any] = {}
    for p in op.params:
        spec: dict[str, Any] = {"type": p.type, "description": p.description}
        if p.enum:
            spec["enum"] = list(p.enum)
        if p.type == "array":
            spec["items"] = {"type": p.items}
        if p.default is not None:
            spec["default"] = p.default
        if p.minimum is not None:
            spec["minimum"] = p.minimum
        props[p.name] = spec
    return {
        "name": op.name,
        "description": f"[{TIER_LABEL[op.tier]}] {op.description}",
        "parameters": {
            "type": "object",
            "properties": props,
            "required": [p.name for p in op.params if p.required],
            "additionalProperties": False,
        },
    }


def _coerce(p: Param, value: Any) -> Any:
    if p.type == "string":
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            value = str(value)
        if not isinstance(value, str):
            raise InvalidArguments(f"'{p.name}' must be a string.")
        value = value.strip()
        if p.enum and value not in p.enum:
            raise InvalidArguments(f"'{p.name}' must be one of: {', '.join(p.enum)}.")
        return value
    if p.type == "integer":
        if isinstance(value, bool):
            raise InvalidArguments(f"'{p.name}' must be an integer.")
        if isinstance(value, str) and _INT_RE.fullmatch(value.strip()):
            value = int(value.strip())
        if not isinstance(value, int):
            raise InvalidArguments(f"'{p.name}' must be an integer.")
        if p.minimum is not None and value < p.minimum:
            raise InvalidArguments(f"'{p.name}' must be ≥ {p.minimum}.")
        return value
    if p.type == "boolean":
        if isinstance(value, str) and value.strip().lower() in ("true", "false"):
            value = value.strip().lower() == "true"
        if not isinstance(value, bool):
            raise InvalidArguments(f"'{p.name}' must be true or false.")
        return value
    if p.type == "array":
        if isinstance(value, str):
            value = [s for s in value.split(",")]
        if not isinstance(value, list) or not all(isinstance(x, str) for x in value):
            raise InvalidArguments(f"'{p.name}' must be a list of strings.")
        return [x.strip() for x in value if x.strip()]
    raise InvalidArguments(f"Unsupported parameter type for '{p.name}'.")


def coerce_args(op: Op, args: Mapping[str, Any] | None) -> dict[str, Any]:
    args = dict(args or {})
    known = {p.name for p in op.params}
    unknown = sorted(set(args) - known)
    if unknown:
        raise InvalidArguments(f"Unknown argument(s) for {op.name}: {', '.join(unknown)}.")
    out: dict[str, Any] = {}
    for p in op.params:
        value = args.get(p.name)
        if value is not None and value != "" and value != []:
            value = _coerce(p, value)
        if value is None or value == "" or value == []:
            if p.required:
                raise InvalidArguments(f"'{p.name}' is required.")
            if p.default is not None:
                out[p.name] = p.default
            continue
        out[p.name] = value
    return out


def ps_params(op: Op, args: Mapping[str, Any]) -> dict[str, Any]:
    by_name = {p.name: p for p in op.params}
    return {by_name[k].ps_name: v for k, v in args.items() if k in by_name}


def target_of(op: Op, args: Mapping[str, Any]) -> str:
    if op.target is not None:
        return str(op.target(args))
    for p in op.params:
        if p.required and p.name in args:
            value = args[p.name]
            return ", ".join(value) if isinstance(value, list) else str(value)
    return ""
