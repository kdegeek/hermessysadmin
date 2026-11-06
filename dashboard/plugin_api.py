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

from fastapi import APIRouter, Request

_ROOT = Path(__file__).resolve().parent.parent
_CORE = "hermes_sysadmin_core"


def _load_core() -> None:
    if _CORE in sys.modules:
        return
    pkg_dir = _ROOT / "sysadmin"
    spec = importlib.util.spec_from_file_location(_CORE, pkg_dir / "__init__.py", submodule_search_locations=[str(pkg_dir)])
    module = importlib.util.module_from_spec(spec)
    sys.modules[_CORE] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        # Never leave a half-initialised package registered for the next load.
        for key in [k for k in sys.modules if k == _CORE or k.startswith(_CORE + ".")]:
            sys.modules.pop(key, None)
        raise


_load_core()
_api = importlib.import_module(f"{_CORE}.api")
_runtime = importlib.import_module(f"{_CORE}.runtime")
_errors = importlib.import_module(f"{_CORE}.errors")

router = APIRouter()


async def _with_service(fn_name: str, *args: Any, **kwargs: Any) -> dict[str, Any]:
    def work() -> dict[str, Any]:
        try:  # never surface a 500 to the Desktop page
            return getattr(_api, fn_name)(_runtime.get_service(), *args, **kwargs)
        except Exception as exc:
            return _errors.error_result(exc)

    return await asyncio.to_thread(work)


async def _body(request: Request) -> dict[str, Any]:
    """The JSON object body, or {} for an empty, malformed or non-object body."""
    try:
        data = await request.json()
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def _limit(value: Optional[str]) -> int:
    try:
        return min(max(int(value), 1), 1000)
    except (TypeError, ValueError):
        return 100


@router.get("/health")
async def health() -> dict[str, Any]:
    return await _with_service("health")


@router.post("/test-connection")
async def test_connection() -> dict[str, Any]:
    return await _with_service("test_connection")


@router.get("/ops")
async def list_ops() -> dict[str, Any]:
    def work() -> dict[str, Any]:
        try:
            return _api.list_ops()
        except Exception as exc:
            return _errors.error_result(exc)

    return await asyncio.to_thread(work)


@router.post("/ops/{name}/decision")
async def op_decision(name: str, request: Request) -> dict[str, Any]:
    return await _with_service("decision", name, await _body(request))


@router.post("/ops/{name}/preview")
async def op_preview(name: str, request: Request) -> dict[str, Any]:
    return await _with_service("preview", name, await _body(request))


@router.post("/ops/{name}")
async def op_run(name: str, request: Request) -> dict[str, Any]:
    return await _with_service("run_op", name, await _body(request))


@router.get("/catalog")
async def catalog() -> dict[str, Any]:
    return await _with_service("catalog")


@router.get("/overview")
async def overview() -> dict[str, Any]:
    return await _with_service("overview")


@router.get("/audit")
async def audit(
    limit: Optional[str] = None,
    actor: Optional[str] = None,
    decision: Optional[str] = None,
) -> dict[str, Any]:
    return await _with_service("audit", limit=_limit(limit), actor=actor, decision=decision)


@router.post("/refresh")
async def refresh() -> dict[str, Any]:
    return await _with_service("refresh")
