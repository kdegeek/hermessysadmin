"""Registers every operation as a Hermes agent tool. Handlers never raise."""

from __future__ import annotations

import json
from typing import Any, Callable

from . import catalog, runtime
from .config import load_settings
from .errors import error_result
from .registry import OPS, schema_for

EMOJI = {
    "ad_domain": "🏢",
    "ad_users": "👤",
    "ad_gpo": "📜",
    "ad_rdp": "🖥️",
    "ad_backup": "💾",
    "fleet": "🗂️",
    "ad_meta": "🛠️",
    "catalog": "📚",
}


def make_handler(name: str) -> Callable[..., str]:
    def handler(args: dict | None = None, **kwargs: Any) -> str:
        try:
            service = runtime.get_service()
            session = str(kwargs.get("session_id") or kwargs.get("task_id") or "")
            # The pre_tool_call hook has already obtained any approval Hermes required;
            # Service.call() still re-checks blocks (protected objects, read-only mode).
            result = service.call(name, args or {}, actor="agent", session=session, approved=True)
        except Exception as exc:
            result = error_result(exc)
        return json.dumps(result, default=str, ensure_ascii=False)

    handler.__name__ = f"hermes_sysadmin_{name}"
    return handler


def make_catalog_run_handler() -> Callable[..., str]:
    def handler(args: dict | None = None, **kwargs: Any) -> str:
        try:
            name, merged = catalog.run_target(args)
            service = runtime.get_service()
            session = str(kwargs.get("session_id") or kwargs.get("task_id") or "")
            result = service.call(name, merged, actor="agent", session=session, approved=True)
        except Exception as exc:
            result = error_result(exc)
        return json.dumps(result, default=str, ensure_ascii=False)

    handler.__name__ = "hermes_sysadmin_catalog_run"
    return handler


CATALOG_RUN_SCHEMA = {
    "name": "catalog_run",
    "description": (
        "[tier of the entry] Run a vetted catalog entry by id (find ids with catalog_search, parameters with "
        "catalog_get). Writes need approval; targeting more than 10 machines, an OU, all machines or a domain "
        "controller is high-risk."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "id": {"type": "string"},
            "params": {"type": "object"},
            "computers": {"type": "array", "items": {"type": "string"}},
            "ou": {"type": "string"},
        },
        "required": ["id"],
        "additionalProperties": False,
    },
}


def _escape_enabled() -> bool:
    return load_settings().enable_powershell_escape


def register_tools(ctx: Any) -> list[str]:
    names: list[str] = []
    for op in sorted(OPS.values(), key=lambda o: o.name):
        if op.name.startswith("t_") or op.catalog:
            continue
        ctx.register_tool(
            name=op.name,
            toolset=op.toolset,
            schema=schema_for(op),
            handler=make_handler(op.name),
            check_fn=_escape_enabled if op.name == "ad_powershell" else None,
            description=op.description,
            emoji=EMOJI.get(op.toolset, "🏢"),
        )
        names.append(op.name)
    ctx.register_tool(
        name="catalog_run",
        toolset="catalog",
        schema=CATALOG_RUN_SCHEMA,
        handler=make_catalog_run_handler(),
        description=CATALOG_RUN_SCHEMA["description"],
        emoji=EMOJI["catalog"],
    )
    names.append("catalog_run")
    return names
