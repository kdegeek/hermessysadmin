"""Pinned PowerShell Gallery modules: lock-file backed status and verified install (jump host only)."""

from __future__ import annotations

import json
from typing import Any, Mapping

from ..catalog import CATALOG_DIR
from ..registry import Op, Param, register

TOOLSET = "catalog"
LOCK_PATH = CATALOG_DIR / "modules.lock.json"


def lock_text() -> str:
    """The lock file as compact JSON, passed to the scripts as their Lock parameter."""
    return json.dumps(json.loads(LOCK_PATH.read_text(encoding="utf-8")), separators=(",", ":"))


def lock_names() -> tuple[str, ...]:
    return tuple(m["name"] for m in json.loads(LOCK_PATH.read_text(encoding="utf-8"))["modules"])


def _inject_lock(settings: Any) -> Mapping[str, Any]:
    return {"Lock": lock_text()}


register(Op(
    name="catalog_module_status", toolset=TOOLSET, tier="R", script="catalog_module_status",
    description=(
        "Status of the pinned PowerShell Gallery modules on the jump host: installed, hash-verified at install, "
        "and signature still valid. Catalog entries marked gallery:<name>@<version> need their module installed."
    ),
    inject=_inject_lock, cache_ttl=60,
))

register(Op(
    name="catalog_module_install", toolset=TOOLSET, tier="H", script="catalog_module_install",
    description=(
        "Install a pinned PowerShell Gallery module (and the pinned modules it requires) into the plugin-owned "
        "folder on the jump host. Downloads from powershellgallery.com, checks the package SHA-512 against the lock "
        "file and, where the lock names a signer, the Authenticode signatures. Never touches the machine PSModulePath."
    ),
    params=(Param("name", "string", "Pinned module name.", required=True, enum=lock_names()),),
    preview=True, inject=_inject_lock,
    enabled=lambda settings: bool(lock_names()),  # nothing is pinned in v0.2, so there is nothing to install
))
