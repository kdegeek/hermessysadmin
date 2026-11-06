"""User, group, lockout and AD Recycle Bin operations."""

from __future__ import annotations

from typing import Any, Mapping

from ..policy import PRIVILEGED_DEFAULT, is_privileged_group, normalize_identity
from ..registry import Op, Param, register

TOOLSET = "ad_users"
IDENTITY = Param("identity", "string", "sAMAccountName, UPN or distinguished name of the user.", required=True)


def privileged_group_names(settings: Any) -> list[str]:
    names = list(PRIVILEGED_DEFAULT) + [normalize_identity(g) for g in settings.privileged_groups]
    return sorted(set(names))


def _privileged_change(args: Mapping[str, Any], settings: Any, facts: Any) -> bool:
    return is_privileged_group(str(args.get("group") or ""), settings)


def with_privileged(obj: Mapping[str, Any], settings: Any) -> dict[str, Any]:
    groups = obj.get("groups") or []
    name = obj.get("name") or ""
    flag = any(is_privileged_group(g, settings) for g in groups) or (
        "groups" not in obj and bool(name) and is_privileged_group(name, settings)
    )
    return {**obj, "privileged": flag}


def _post_user_get(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    return with_privileged(data or {}, settings)


def _post_user_list(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    data = data or {}
    items = [with_privileged(u, settings) for u in data.get("items") or []]
    limit = int(args.get("limit") or 200)
    if args.get("privileged"):
        items = [u for u in items if u["privileged"]]
        total = len(items)
    else:
        total = int(data.get("total", len(items)))
    return {"items": items[:limit], "total": total, "limit": limit}


def _post_groups(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    data = dict(data or {})
    data["items"] = [{**g, "privileged": is_privileged_group(g.get("name", ""), settings)} for g in data.get("items") or []]
    return data


def _post_group_get(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    data = dict(data or {})
    data["privileged"] = is_privileged_group(data.get("name", ""), settings)
    return data


def _post_lockout(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    data = dict(data or {})
    counts: dict[str, int] = {}
    for event in data.get("events") or []:
        source = str(event.get("source") or "").strip() or "(unknown)"
        counts[source] = counts.get(source, 0) + 1
    sources = sorted(({"source": s, "count": c} for s, c in counts.items()), key=lambda x: (-x["count"], x["source"]))
    data["sources"] = sources
    data["likely_source"] = sources[0]["source"] if sources else None
    return data


def _members_target(arrow: str):
    return lambda a: f"{a.get('group', '')} {arrow} {', '.join(a.get('members') or [])}"


# ---- reads ---------------------------------------------------------------

register(Op(
    name="ad_user_get", toolset=TOOLSET, tier="R", script="ad_user_get",
    description="Full detail for one user: status, lockout, password expiry, last logon, attributes and group memberships.",
    params=(IDENTITY,), post=_post_user_get,
))

register(Op(
    name="ad_user_list", toolset=TOOLSET, tier="R", script="ad_user_list",
    description=(
        "List users with filters: name query, OU, status (enabled/disabled/locked), password state "
        "(expired/expiring/never_expires), stale for N days, privileged only."
    ),
    params=(
        Param("query", "string", "Name fragment (ambiguous name resolution)."),
        Param("ou", "string", "Distinguished name of the OU to search.", ps="SearchBase"),
        Param("status", "string", "Account status filter.", enum=("any", "enabled", "disabled", "locked"), default="any"),
        Param("password", "string", "Password state filter.", enum=("any", "expired", "expiring", "never_expires"), default="any"),
        Param("stale_days", "integer", "Only users with no logon in this many days.", minimum=1),
        Param("expiring_days", "integer", "Window for 'expiring'.", default=7, minimum=1),
        Param("privileged", "boolean", "Only members of privileged groups.", default=False),
        Param("limit", "integer", "Maximum users returned.", default=200, minimum=1),
    ),
    post=_post_user_list,
))

register(Op(
    name="ad_lockout_source", toolset=TOOLSET, tier="R", script="ad_lockout_source",
    description=(
        "Find what is locking an account out: lockout events (4740) on the PDC emulator with the calling "
        "computer, and bad-password counts per domain controller."
    ),
    params=(IDENTITY, Param("hours", "integer", "How far back to look.", default=24, minimum=1)),
    post=_post_lockout,
))

register(Op(
    name="ad_group_get", toolset=TOOLSET, tier="R", script="ad_group_get",
    description="One group's scope, category, description, manager and members.",
    params=(
        Param("identity", "string", "Group name, sAMAccountName or DN.", required=True),
        Param("limit", "integer", "Maximum members returned.", default=500, minimum=1),
    ),
    post=_post_group_get,
))

register(Op(
    name="ad_group_list", toolset=TOOLSET, tier="R", script="ad_group_list",
    description="List groups (optionally matching a name) with scope, category and member count.",
    params=(Param("query", "string", "Name fragment."), Param("limit", "integer", "Maximum groups.", default=100, minimum=1)),
    post=_post_groups,
))

register(Op(
    name="ad_recycle_bin_list", toolset=TOOLSET, tier="R", script="ad_recycle_bin_list",
    description="List deleted objects in the AD Recycle Bin with their last known parent OU.",
    params=(
        Param("kind", "string", "Object class filter.", enum=("any", "user", "group", "computer", "ou"), default="any"),
        Param("query", "string", "Name fragment."),
        Param("limit", "integer", "Maximum results.", default=100, minimum=1),
    ),
))

# ---- writes --------------------------------------------------------------

register(Op(
    name="ad_user_create", toolset=TOOLSET, tier="W", script="ad_user_create",
    description=(
        "Create a user. Give an OU, or a template user whose OU, department and (non-privileged) groups are copied. "
        "If no password is given a strong one is generated and returned once."
    ),
    params=(
        Param("sam", "string", "sAMAccountName (logon name) for the new user.", required=True),
        Param("given_name", "string", "First name."),
        Param("surname", "string", "Last name."),
        Param("display_name", "string", "Display name; defaults to 'First Last'."),
        Param("ou", "string", "DN of the OU to create the user in.", ps="Path"),
        Param("template", "string", "sAMAccountName of a user to copy OU, department and groups from."),
        Param("email", "string", "Email address."),
        Param("title", "string", "Job title."),
        Param("department", "string", "Department."),
        Param("description", "string", "Description."),
        Param("password", "string", "Initial password. Omit to generate one."),
        Param("must_change", "boolean", "Require a password change at first logon.", default=True),
        Param("enabled", "boolean", "Create the account enabled.", default=True),
    ),
    target=lambda a: a.get("sam", ""),
    identities=("sam",),
    inject=lambda s: {"PrivilegedGroups": privileged_group_names(s)},
))

register(Op(
    name="ad_user_update", toolset=TOOLSET, tier="W", script="ad_user_update",
    description="Change a user's profile attributes (display name, names, email, title, department, office, phone, description, manager).",
    params=(
        IDENTITY,
        Param("display_name", "string", "Display name."),
        Param("given_name", "string", "First name."),
        Param("surname", "string", "Last name."),
        Param("email", "string", "Email address."),
        Param("title", "string", "Job title."),
        Param("department", "string", "Department."),
        Param("office", "string", "Office."),
        Param("phone", "string", "Office phone."),
        Param("description", "string", "Description."),
        Param("manager", "string", "sAMAccountName of the manager."),
    ),
    identities=("identity",),
))

register(Op(
    name="ad_user_reset_password", toolset=TOOLSET, tier="W", script="ad_user_reset_password",
    description="Reset a user's password (generated and returned once if not given), optionally forcing a change at next logon and unlocking.",
    params=(
        IDENTITY,
        Param("password", "string", "New password. Omit to generate one."),
        Param("must_change", "boolean", "Require a change at next logon.", default=True),
        Param("unlock", "boolean", "Unlock the account if it is locked.", default=True),
    ),
    identities=("identity",),
))

for _name, _desc in (
    ("ad_user_unlock", "Unlock a locked-out user account."),
    ("ad_user_enable", "Enable a disabled user account."),
):
    register(Op(name=_name, toolset=TOOLSET, tier="W", script=_name, description=_desc, params=(IDENTITY,), identities=("identity",)))

register(Op(
    name="ad_user_disable", toolset=TOOLSET, tier="W", script="ad_user_disable",
    description="Disable a user account, optionally stamping the description (e.g. 'Disabled 2026-11-05 ticket 4411').",
    params=(IDENTITY, Param("note", "string", "Text to write into the description.")),
    identities=("identity",),
))

register(Op(
    name="ad_user_move", toolset=TOOLSET, tier="W", script="ad_user_move",
    description="Move a user to another OU.",
    params=(IDENTITY, Param("target_ou", "string", "DN of the destination OU.", required=True)),
    identities=("identity",),
))

_MEMBERS = (
    Param("group", "string", "Group name, sAMAccountName or DN.", required=True),
    Param("members", "array", "sAMAccountNames of users, groups or computers (computers end in $).", required=True),
)

register(Op(
    name="ad_group_add_member", toolset=TOOLSET, tier="W", script="ad_group_add_member",
    description="Add members to a group. Privileged groups (Domain Admins etc.) make this a high-risk change.",
    params=_MEMBERS, target=_members_target("←"), identities=("group", "members"),
    escalate=_privileged_change, preview=True,
))

register(Op(
    name="ad_group_remove_member", toolset=TOOLSET, tier="W", script="ad_group_remove_member",
    description="Remove members from a group. Privileged groups make this a high-risk change.",
    params=_MEMBERS, target=_members_target("→"), identities=("group", "members"),
    escalate=_privileged_change, preview=True,
))

register(Op(
    name="ad_recycle_bin_restore", toolset=TOOLSET, tier="W", script="ad_recycle_bin_restore",
    description="Restore a deleted object from the AD Recycle Bin (by objectGUID from ad_recycle_bin_list), optionally into another OU.",
    params=(
        Param("identity", "string", "objectGUID of the deleted object.", required=True),
        Param("target_ou", "string", "DN to restore into instead of the last known parent."),
    ),
))

register(Op(
    name="ad_user_delete", toolset=TOOLSET, tier="H", script="ad_user_delete",
    description="Delete a user account. High-risk: shows a preview with current groups and Recycle Bin state first.",
    params=(IDENTITY,), identities=("identity",), preview=True,
))
