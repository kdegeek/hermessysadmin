"""Domain-wide visibility ops: DCs, health, overview counts, search, connection test."""

from __future__ import annotations

from typing import Any, Mapping

from ..policy import is_privileged_group
from ..registry import Op, Param, register

TOOLSET = "ad_domain"
_RANK = {"ok": 0, "warn": 1, "bad": 2}
_REQUIRED_SERVICES = ("NTDS", "Netlogon", "KDC")


def worst(statuses: list[str]) -> str:
    return max(statuses, key=lambda s: _RANK.get(s, 2), default="ok")


def dc_status(dc: Mapping[str, Any]) -> str:
    if not dc.get("reachable"):
        return "bad"
    services = dc.get("services") or {}
    if any(services.get(name) != "Running" for name in _REQUIRED_SERVICES):
        return "bad"
    if dc.get("sysvol_shared") is False or dc.get("netlogon_shared") is False:
        return "bad"
    skew = dc.get("time_skew_seconds")
    if isinstance(skew, (int, float)) and abs(skew) >= 300:
        return "bad"
    status = "ok"
    if services.get("DNS") not in ("Running", "Missing", None):
        status = "warn"
    if services.get("W32Time") not in ("Running", None):
        status = "warn"
    if isinstance(skew, (int, float)) and abs(skew) >= 60:
        status = "warn"
    replication = dc.get("replication") or {}
    if replication.get("failures") or replication.get("error"):
        status = "warn"
    return status


def _post_dc_health(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    items = []
    for dc in (data or {}).get("items") or []:
        items.append({**dc, "status": dc_status(dc)})
    errors = (data or {}).get("errors") or []
    overall = worst([d["status"] for d in items] + (["bad"] if errors else []))
    return {"items": items, "errors": errors, "status": overall}


def _post_connection_test(data: Any, args: Mapping[str, Any], settings: Any) -> Any:
    data = dict(data or {})
    local = settings.transport == "local"
    groups = [str(g) for g in data.get("groups") or []]
    data["privileged_memberships"] = [g for g in groups if is_privileged_group(g, settings)]
    data["transport"] = settings.transport
    data["run_as"] = settings.run_as if local else None
    data["local_identity"] = data.get("identity")
    error = str(data.get("network_identity_error") or "")
    if error and settings.password:
        error = error.replace(settings.password, "***")  # defence in depth: never echo the secret
        data["network_identity_error"] = error
    modules = data.get("modules") or {}
    where = "this machine" if local else "the jump host"
    warnings = []
    if not local and not data.get("is_domain_controller"):
        warnings.append(
            "The jump host is not a domain controller; GPO operations will fail because "
            "GroupPolicy cmdlets cannot use explicit credentials (double hop). Use a DC as the jump host."
        )
    if error:
        who = settings.username if local and settings.run_as == "account" else (data.get("identity") or "this identity")
        hint = (
            " With 'Run as: account' Windows does not check the password when PowerShell starts; "
            "a wrong password shows up here, on the first network logon. Check the username and password."
            if local and settings.run_as == "account" else ""
        )
        warnings.append(f"{who} could not authenticate to (or run a command on) domain controller {data.get('dc') or ''}: {error}.{hint}")
    for name in ("ActiveDirectory", "GroupPolicy"):
        if not modules.get(name):
            warnings.append(f"The {name} PowerShell module is not installed on {where}.")
    data["warnings"] = warnings
    return data


register(Op(
    name="ad_dc_list",
    toolset=TOOLSET,
    tier="R",
    script="ad_dc_list",
    description="List the domain controllers with site, IP, OS, global-catalog/RODC flags and FSMO roles.",
    cache_ttl=300,
))

register(Op(
    name="ad_domain_overview",
    toolset=TOOLSET,
    tier="R",
    script="ad_domain_overview",
    description=(
        "Domain summary: functional levels, FSMO role holders, Recycle Bin state, and counts of users "
        "(enabled, disabled, locked, passwords expiring soon), computers (stale), groups, OUs and GPOs."
    ),
    params=(
        Param("stale_days", "integer", "Computers with no logon for this many days count as stale.", default=90, minimum=1),
        Param("expiring_days", "integer", "Passwords expiring within this many days count as expiring.", default=7, minimum=1),
    ),
    cache_ttl=60,
))

register(Op(
    name="ad_dc_health",
    toolset=TOOLSET,
    tier="R",
    script="ad_dc_health",
    description=(
        "Health of every domain controller: reachability, NTDS/DNS/Netlogon/KDC/W32Time service state, "
        "SYSVOL/NETLOGON shares, uptime, time skew and replication failures, with an ok/warn/bad status."
    ),
    post=_post_dc_health,
    cache_ttl=60,
))

register(Op(
    name="ad_search",
    toolset=TOOLSET,
    tier="R",
    script="ad_search",
    description=(
        "Search AD objects by name (ambiguous name resolution) or by a raw LDAP filter starting with '('. "
        "Returns name, DN, class, sAMAccountName and description."
    ),
    params=(
        Param("query", "string", "Name fragment, sAMAccountName, or an LDAP filter like (mail=*@corp.com).", required=True),
        Param("kind", "string", "Restrict to one object class.", enum=("any", "user", "group", "computer", "ou"), default="any"),
        Param("limit", "integer", "Maximum results.", default=25, minimum=1),
    ),
))

register(Op(
    name="ad_connection_test",
    toolset=TOOLSET,
    tier="R",
    script="ad_connection_test",
    description=(
        "Test the connection: the transport (local PowerShell or WinRM jump host), the machine PowerShell runs on "
        "(OS, whether it is a DC, modules present), the local identity, the identity a domain controller sees "
        "(network_identity) and its privileged group memberships, plus setup warnings."
    ),
    post=_post_connection_test,
))
