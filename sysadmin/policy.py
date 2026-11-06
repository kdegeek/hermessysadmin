"""Tiered safety policy shared by the approval hook, the service and the dashboard."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterable, Mapping, Protocol

PROTECTED_DEFAULT = ("krbtgt", "administrator")
PRIVILEGED_DEFAULT = (
    "domain admins",
    "enterprise admins",
    "schema admins",
    "administrators",
    "account operators",
    "server operators",
    "backup operators",
    "print operators",
    "group policy creator owners",
    "dnsadmins",
    "key admins",
    "enterprise key admins",
)


@dataclass(frozen=True)
class Decision:
    action: str  # "allow" | "approve" | "block"
    tier: str  # "R" | "W" | "H" | "P"
    reason: str
    needs_preview: bool = False


class Facts(Protocol):
    def domain_controllers(self) -> list[str] | None: ...


class NoFacts:
    def domain_controllers(self) -> list[str] | None:
        return None


def normalize_identity(value: str) -> str:
    text = value.strip()
    if text.lower().startswith("cn="):
        text = text[3:].split(",", 1)[0]
    if "\\" in text:
        text = text.split("\\", 1)[1]
    if "@" in text:
        text = text.split("@", 1)[0]
    return text.strip().lower()


def is_privileged_group(name: str, settings: Any) -> bool:
    pool = set(PRIVILEGED_DEFAULT) | {normalize_identity(g) for g in settings.privileged_groups}
    return normalize_identity(name) in pool


def is_domain_controller_name(host: str, dcs: Iterable[str]) -> bool:
    short = host.strip().lower().split(".", 1)[0]
    return any(short == d.strip().lower().split(".", 1)[0] for d in dcs)


def _protected_hit(op: Any, args: Mapping[str, Any], settings: Any) -> str | None:
    pool = set(PROTECTED_DEFAULT) | {normalize_identity(p) for p in settings.protected_objects}
    for key in op.identities:
        value = args.get(key)
        for item in value if isinstance(value, list) else [value]:
            if isinstance(item, str) and item and normalize_identity(item) in pool:
                return item
    return None


def decide(op: Any, args: Mapping[str, Any], settings: Any, facts: Facts | None = None) -> Decision:
    if op.tier == "R":
        return Decision("allow", "R", "Read-only operation.")
    hit = _protected_hit(op, args, settings)
    if hit:
        return Decision(
            "block", "P",
            f"'{hit}' is a protected object; changes to it are blocked by the hermes-sysadmin policy.",
        )
    escalated = bool(op.escalate and op.escalate(args, settings, facts or NoFacts()))
    tier = "H" if op.tier == "H" or escalated else "W"
    if settings.mode == "read-only":
        return Decision("block", tier, "hermes-sysadmin is in read-only mode; writes are disabled in its settings.")
    if tier == "H":
        return Decision("approve", "H", "High-risk change: requires approval with a preview.", needs_preview=op.preview)
    if settings.mode == "permissive":
        return Decision("allow", "W", "Permissive mode: standard writes run without approval.")
    return Decision("approve", "W", "Write operation: requires approval.")
