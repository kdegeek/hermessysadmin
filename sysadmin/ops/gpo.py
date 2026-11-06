"""Group Policy operations."""

from __future__ import annotations

import re
from typing import Any, Mapping

from ..registry import Op, Param, register

TOOLSET = "ad_gpo"
GPO = Param("identity", "string", "GPO display name or GUID.", required=True)
TARGET = Param("target", "string", "DN of the OU, domain or site the link is on.", required=True)
_DEFAULT_POLICIES = {
    "default domain policy",
    "default domain controllers policy",
    "31b2f340-016d-11d2-945f-00c04fb984f9",
    "6ac1786c-016f-11d2-945f-00c04fb984f9",
}


_GUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.IGNORECASE)


def _rdns(dn: str) -> list[str]:
    """Lower-cased RDNs with the whitespace RFC 4514 allows around '=' and ',' removed."""
    parts = re.split(r"(?<!\\),", dn)
    out = []
    for part in parts:
        attr, sep, value = part.partition("=")
        out.append(f"{attr.strip().lower()}{sep}{' '.join(value.split()).lower()}")
    return out


def is_wide_scope(dn: str) -> bool:
    rdns = _rdns(dn)
    if not rdns or not rdns[0]:
        return False
    return (
        rdns[0].startswith("dc=")
        or (rdns[0] == "ou=domain controllers" and len(rdns) > 1 and rdns[1].startswith("dc="))
        or "cn=sites" in rdns
    )


def is_default_policy(identity: str) -> bool:
    guid = _GUID_RE.search(identity)
    if guid:
        return guid.group(0).lower() in _DEFAULT_POLICIES
    return " ".join(identity.split()).lower() in _DEFAULT_POLICIES


def gpo_issues(gpo: Mapping[str, Any]) -> list[str]:
    issues: list[str] = []
    links = gpo.get("links") or []
    if not links:
        issues.append("Unlinked")
    elif all(not link.get("enabled") for link in links):
        issues.append("All links disabled")
    if gpo.get("status") == "AllSettingsDisabled":
        issues.append("All settings disabled")
    user = gpo.get("user_version") or {}
    computer = gpo.get("computer_version") or {}
    if user.get("ad") == 0 and computer.get("ad") == 0:
        issues.append("Empty (no settings)")
    for scope, version in (("computer", computer), ("user", user)):
        if version.get("ad") is not None and version.get("ad") != version.get("sysvol"):
            issues.append(f"Version mismatch: {scope} AD {version.get('ad')} / SYSVOL {version.get('sysvol')}")
    return issues


def _post_list(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    items = [{**g, "health": gpo_issues(g)} for g in (data or {}).get("items") or []]
    return {
        "items": items,
        "summary": {
            "total": len(items),
            "needs_attention": sum(1 for g in items if g["health"]),
            "unlinked": sum(1 for g in items if "Unlinked" in g["health"]),
        },
    }


def _post_health(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    listed = _post_list(data, args, settings)
    return {"items": [g for g in listed["items"] if g["health"]], "summary": listed["summary"]}


def _wide(args: Mapping[str, Any], settings: Any, facts: Any) -> bool:
    return is_wide_scope(str(args.get("target") or ""))


def _default(args: Mapping[str, Any], settings: Any, facts: Any) -> bool:
    return is_default_policy(str(args.get("identity") or ""))


def _link_target(a: Mapping[str, Any]) -> str:
    return f"{a.get('identity', '')} @ {a.get('target', '')}"


register(Op(
    name="gpo_list", toolset=TOOLSET, tier="R", script="gpo_list",
    description="List every GPO with status, versions, WMI filter, where it is linked (enabled/enforced/order) and health issues.",
    post=_post_list, cache_ttl=60,
))

register(Op(
    name="gpo_health", toolset=TOOLSET, tier="R", script="gpo_list",
    description="GPOs that need attention: unlinked, all links disabled, all settings disabled, empty, or AD/SYSVOL version mismatch.",
    post=_post_health, cache_ttl=60,
))

register(Op(
    name="gpo_get", toolset=TOOLSET, tier="R", script="gpo_get",
    description="One GPO: status, versions, links, security filtering (who it applies to) and delegation.",
    params=(GPO,),
))

register(Op(
    name="gpo_report", toolset=TOOLSET, tier="R", script="gpo_report",
    description="Settings report for a GPO: 'summary' lists configured settings per extension; 'html' returns the full GPMC HTML report.",
    params=(GPO, Param("format", "string", "Report format.", enum=("summary", "html"), default="summary")),
))

register(Op(
    name="gpo_rsop", toolset=TOOLSET, tier="R", script="gpo_rsop",
    description="Resultant Set of Policy on a computer (optionally for a user who has logged on there): which GPOs applied or were filtered out.",
    params=(
        Param("computer", "string", "Computer DNS name.", required=True),
        Param("user", "string", "DOMAIN\\user to include user-side results for."),
    ),
))

register(Op(
    name="gpo_backups", toolset=TOOLSET, tier="R", script="gpo_backups",
    description="List GPO backups taken by this plugin (optionally for one GPO), newest first.",
    params=(Param("identity", "string", "GPO display name or GUID."),),
))

register(Op(
    name="gpo_create", toolset=TOOLSET, tier="W", script="gpo_create",
    description="Create a new, unlinked GPO.",
    params=(Param("name", "string", "Display name.", required=True), Param("comment", "string", "Description.")),
    identities=("name",),
))

register(Op(
    name="gpo_backup", toolset=TOOLSET, tier="W", script="gpo_backup",
    description="Back up a GPO on the domain controller.",
    params=(GPO, Param("comment", "string", "Backup comment.", default="hermes-sysadmin backup")),
))

register(Op(
    name="gpo_update_hosts", toolset=TOOLSET, tier="W", script="gpo_update_hosts",
    description="Run gpupdate on computers (by name and/or every computer in an OU), with per-host results.",
    params=(
        Param("computers", "array", "Computer DNS names."),
        Param("ou", "string", "DN of an OU whose computers should refresh policy."),
        Param("force", "boolean", "Use /force.", default=True),
    ),
    target=lambda a: ", ".join(a.get("computers") or []) or a.get("ou", ""),
))

register(Op(
    name="gpo_link", toolset=TOOLSET, tier="W", script="gpo_link",
    description="Link a GPO to an OU, the domain or a site. Linking at the domain root, Domain Controllers or a site is high-risk.",
    params=(
        GPO, TARGET,
        Param("enforced", "boolean", "Enforce the link.", default=False),
        Param("enabled", "boolean", "Enable the link.", default=True),
    ),
    target=_link_target, identities=("identity",), escalate=_wide, preview=True,
))

register(Op(
    name="gpo_unlink", toolset=TOOLSET, tier="W", script="gpo_unlink",
    description="Remove a GPO link from an OU, the domain or a site.",
    params=(GPO, TARGET),
    target=_link_target, identities=("identity",), escalate=_wide, preview=True,
))

register(Op(
    name="gpo_set_link", toolset=TOOLSET, tier="W", script="gpo_set_link",
    description="Change an existing link: enforce/unenforce and/or enable/disable it.",
    params=(
        GPO, TARGET,
        Param("enforced", "boolean", "Enforced state."),
        Param("enabled", "boolean", "Enabled state."),
    ),
    target=_link_target, identities=("identity",), escalate=_wide, preview=True,
))

register(Op(
    name="gpo_set_status", toolset=TOOLSET, tier="W", script="gpo_set_status",
    description="Enable or disable a GPO's user and/or computer settings.",
    params=(
        GPO,
        Param("status", "string", "New status.", required=True,
              enum=("AllSettingsEnabled", "AllSettingsDisabled", "UserSettingsDisabled", "ComputerSettingsDisabled")),
    ),
    identities=("identity",), escalate=_default,
))

register(Op(
    name="gpo_set_security_filter", toolset=TOOLSET, tier="W", script="gpo_set_security_filter",
    description=(
        "Change who a GPO applies to: grant Apply to principals in 'add', remove it for principals in 'remove'. "
        "Removing Authenticated Users keeps its Read permission so the GPO still processes (MS16-072)."
    ),
    params=(GPO, Param("add", "array", "Groups/users/computers to grant Apply."), Param("remove", "array", "Principals to remove Apply from.")),
    identities=("identity",), escalate=_default,
))

register(Op(
    name="gpo_delete", toolset=TOOLSET, tier="H", destructive=True, script="gpo_delete",
    description="Delete a GPO and its links. A backup is taken automatically first.",
    params=(GPO,), identities=("identity",), preview=True,
))

register(Op(
    name="gpo_restore", toolset=TOOLSET, tier="H", destructive=True, script="gpo_restore",
    description="Restore an existing GPO's settings from a backup (see gpo_backups). The current state is backed up first; links are unchanged. A deleted GPO cannot be restored with this tool: its backup can be imported at the DC with Import-GPO -CreateIfNeeded.",
    params=(GPO, Param("backup_id", "string", "Backup ID from gpo_backups.", required=True)),
    identities=("identity",), preview=True,
))
