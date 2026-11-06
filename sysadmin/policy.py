"""Tiered safety policy shared by the approval hook, the service and the dashboard."""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from typing import Any, Iterable, Mapping, Protocol

log = logging.getLogger(__name__)

_DN_RE = re.compile(r"^\s*cn\s*=", re.IGNORECASE)
_PROTECTED_SID_RE = re.compile(r"^S-1-5-21-\d+-\d+-\d+-(500|502)$", re.IGNORECASE)
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
    "s-1-5-32-544",  # well-known SID of BUILTIN\\Administrators
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


_HEX = "0123456789abcdefABCDEF"


def _first_rdn_value(dn: str) -> str:
    """Value of the first attribute of a DN's first RDN (RFC 4514).

    Honours backslash escapes (``\\,`` and hex pairs such as ``\\6b``), quoted
    values, and stops at an unescaped ``,`` or ``+`` (multi-valued RDN), so every
    spelling AD resolves to the same object normalizes to the same name.
    """
    text = _DN_RE.sub("", dn, count=1)
    out = bytearray()
    quoted = False
    i = 0
    while i < len(text):
        ch = text[i]
        pair = text[i + 1 : i + 3]
        if ch == "\\" and len(pair) == 2 and all(c in _HEX for c in pair):
            out.append(int(text[i + 1 : i + 3], 16))
            i += 3
            continue
        if ch == "\\" and i + 1 < len(text):
            out.extend(text[i + 1].encode())
            i += 2
            continue
        if ch == '"':
            quoted = not quoted
            i += 1
            continue
        if ch in ",+" and not quoted:
            break
        out.extend(ch.encode())
        i += 1
    return out.decode("utf-8", errors="replace")


def normalize_identity(value: str) -> str:
    text = value.strip()
    if _DN_RE.match(text):
        text = _first_rdn_value(text)
    if "\\" in text:
        text = text.split("\\", 1)[1]
    if "@" in text:
        text = text.split("@", 1)[0]
    return text.strip().lower()


# Domain-relative RIDs of privileged groups: Domain Admins, Cert Publishers, Schema Admins,
# Enterprise Admins, Group Policy Creator Owners, Enterprise Key Admins, Key Admins.
_PRIVILEGED_DOMAIN_SID_RE = re.compile(r"^S-1-5-21-\d+-\d+-\d+-(512|517|518|519|520|526|527)$", re.IGNORECASE)
# BUILTIN groups: Administrators, Account/Server/Print/Backup Operators, Replicator.
_PRIVILEGED_BUILTIN_SID_RE = re.compile(r"^S-1-5-32-(544|548|549|550|551|552)$", re.IGNORECASE)
_GUID_RE = re.compile(r"^\{?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\}?$", re.IGNORECASE)


def is_privileged_group(name: str, settings: Any) -> bool:
    """True for privileged group names, their SIDs, and any objectGUID (it cannot be checked by name)."""
    text = name.strip()
    if _PRIVILEGED_DOMAIN_SID_RE.match(text) or _PRIVILEGED_BUILTIN_SID_RE.match(text) or _GUID_RE.match(text):
        return True
    pool = set(PRIVILEGED_DEFAULT) | {normalize_identity(g) for g in settings.privileged_groups}
    return normalize_identity(name) in pool


def is_domain_controller_name(host: str, dcs: Iterable[str]) -> bool:
    short = host.strip().lower().split(".", 1)[0]
    return any(short == d.strip().lower().split(".", 1)[0] for d in dcs)


def _protected_hit(op: Any, args: Mapping[str, Any], settings: Any) -> tuple[str, str] | None:
    """Return ("protected", item) or ("uninterpretable", repr) when the call must be blocked."""
    pool = set(PROTECTED_DEFAULT) | {normalize_identity(p) for p in settings.protected_objects}
    for key in op.identities:
        value = args.get(key)
        is_collection = isinstance(value, (list, tuple, set, frozenset))
        if value is None:
            continue  # absent/None top-level identity: nothing to protect
        for item in (value if is_collection else [value]):
            if not isinstance(item, str):
                return ("uninterpretable", f"{key}={item!r}"[:80])
            if not item:
                continue
            if _PROTECTED_SID_RE.match(item.strip()) or normalize_identity(item) in pool:
                return ("protected", item)
    return None


def _block_safety(tier: str, why: str) -> Decision:
    return Decision("block", tier, f"The hermes-sysadmin safety check failed ({why}); the change was blocked.")


def decide(op: Any, args: Mapping[str, Any], settings: Any, facts: Facts | None = None) -> Decision:
    if getattr(op, "enabled", None) is not None and not op.enabled(settings):
        return Decision("block", op.tier, f"{op.name} is disabled in the hermes-sysadmin settings.")
    if op.tier == "R":
        return Decision("allow", "R", "Read-only operation.")
    hit = _protected_hit(op, args, settings)
    if hit:
        kind, item = hit
        if kind == "uninterpretable":
            return Decision(
                "block", "P",
                f"The identity value ({item}) could not be interpreted; blocked by the hermes-sysadmin policy.",
            )
        return Decision(
            "block", "P",
            f"'{item}' is a protected object; changes to it are blocked by the hermes-sysadmin policy.",
        )
    try:
        escalated = bool(op.escalate and op.escalate(args, settings, facts or NoFacts()))
    except Exception:
        log.exception("hermes-sysadmin: escalate check failed for %s", getattr(op, "name", "?"))
        return _block_safety(op.tier if op.tier in ("W", "H") else "W", "escalation check raised an error")
    tier = "H" if op.tier == "H" or escalated else "W"
    if settings.mode == "read-only":
        return Decision("block", tier, "hermes-sysadmin is in read-only mode; writes are disabled in its settings.")
    if tier == "H":
        return Decision("approve", "H", "High-risk change: requires approval with a preview.", needs_preview=op.preview)
    if settings.mode == "permissive":
        return Decision("allow", "W", "Permissive mode: standard writes run without approval.")
    return Decision("approve", "W", "Write operation: requires approval.")
