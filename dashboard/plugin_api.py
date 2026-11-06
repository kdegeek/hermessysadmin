"""hermes-sysadmin dashboard backend, mounted by Hermes at /api/plugins/hermes-sysadmin/.

Hermes imports this file standalone (spec_from_file_location), so the plugin's `sysadmin`
package is loaded by path under a private module name. All handlers are async and run the
blocking WinRM work in a worker thread so the gateway event loop never stalls. Every route
returns HTTP 200 with {"ok": true, "data": ...} or {"ok": false, "error": {...}}.
"""

from __future__ import annotations

import asyncio
import importlib
import importlib.util
import sys
from pathlib import Path
from typing import Any, Optional

from fastapi import APIRouter, Body, Query

_ROOT = Path(__file__).resolve().parent.parent
_CORE = "hermes_sysadmin_core"


def _load_core() -> None:
    if _CORE in sys.modules:
        return
    pkg_dir = _ROOT / "sysadmin"
    spec = importlib.util.spec_from_file_location(_CORE, pkg_dir / "__init__.py", submodule_search_locations=[str(pkg_dir)])
    module = importlib.util.module_from_spec(spec)
    sys.modules[_CORE] = module
    spec.loader.exec_module(module)


_load_core()
_api = importlib.import_module(f"{_CORE}.api")
_runtime = importlib.import_module(f"{_CORE}.runtime")
_errors = importlib.import_module(f"{_CORE}.errors")

router = APIRouter()


async def _with_service(fn_name: str, *args: Any, **kwargs: Any) -> dict[str, Any]:
    def work() -> dict[str, Any]:
        try:
            service = _runtime.get_service()
        except Exception as exc:  # never surface a 500 to the Desktop page
            return _errors.error_result(exc)
        return getattr(_api, fn_name)(service, *args, **kwargs)

    return await asyncio.to_thread(work)


@router.get("/health")
async def health() -> dict[str, Any]:
    return await _with_service("health")


@router.post("/test-connection")
async def test_connection() -> dict[str, Any]:
    return await _with_service("test_connection")


@router.get("/ops")
async def list_ops() -> dict[str, Any]:
    return await asyncio.to_thread(_api.list_ops)


@router.post("/ops/{name}/decision")
async def op_decision(name: str, body: Optional[dict] = Body(default=None)) -> dict[str, Any]:
    return await _with_service("decision", name, body or {})


@router.post("/ops/{name}/preview")
async def op_preview(name: str, body: Optional[dict] = Body(default=None)) -> dict[str, Any]:
    return await _with_service("preview", name, body or {})


@router.post("/ops/{name}")
async def op_run(name: str, body: Optional[dict] = Body(default=None)) -> dict[str, Any]:
    return await _with_service("run_op", name, body or {})


@router.get("/overview")
async def overview() -> dict[str, Any]:
    return await _with_service("overview")


@router.get("/audit")
async def audit(
    limit: int = Query(100, ge=1, le=1000),
    actor: Optional[str] = None,
    decision: Optional[str] = None,
) -> dict[str, Any]:
    return await _with_service("audit", limit=limit, actor=actor, decision=decision)


@router.post("/refresh")
async def refresh() -> dict[str, Any]:
    return await _with_service("refresh")
