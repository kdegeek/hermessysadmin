import pytest

from sysadmin.config import Settings
from sysadmin.policy import (
    decide,
    is_domain_controller_name,
    is_privileged_group,
    normalize_identity,
)
from sysadmin.registry import Op, Param

READ = Op("t_p_read", "t", "R", "t", "d", params=(Param("identity", "string", "x"),))
WRITE = Op("t_p_write", "t", "W", "t", "d", params=(Param("identity", "string", "x"),), identities=("identity",))
HIGH = Op("t_p_high", "t", "H", "t", "d", params=(Param("identity", "string", "x"),), identities=("identity",), preview=True)
GROUP = Op(
    "t_p_group", "t", "W", "t", "d",
    params=(Param("group", "string", "g"), Param("members", "array", "m")),
    identities=("members",),
    escalate=lambda args, settings, facts: is_privileged_group(args["group"], settings),
)

STRICT = Settings(mode="strict")
PERMISSIVE = Settings(mode="permissive")
READONLY = Settings(mode="read-only")


@pytest.mark.parametrize(
    "op, settings, action, tier",
    [
        (READ, STRICT, "allow", "R"),
        (READ, READONLY, "allow", "R"),
        (WRITE, STRICT, "approve", "W"),
        (WRITE, PERMISSIVE, "allow", "W"),
        (WRITE, READONLY, "block", "W"),
        (HIGH, STRICT, "approve", "H"),
        (HIGH, PERMISSIVE, "approve", "H"),
        (HIGH, READONLY, "block", "H"),
    ],
)
def test_mode_tier_matrix(op, settings, action, tier):
    d = decide(op, {"identity": "bob"}, settings)
    assert (d.action, d.tier) == (action, tier)


def test_high_risk_requests_preview_only_when_op_supports_it():
    assert decide(HIGH, {"identity": "bob"}, STRICT).needs_preview is True
    assert decide(WRITE, {"identity": "bob"}, STRICT).needs_preview is False


@pytest.mark.parametrize("ident", ["krbtgt", "KRBTGT", "CORP\\Administrator", "administrator@corp.local", "CN=krbtgt,CN=Users,DC=corp"])
def test_builtin_protected_objects_are_blocked_in_every_mode(ident):
    for settings in (STRICT, PERMISSIVE):
        d = decide(WRITE, {"identity": ident}, settings)
        assert (d.action, d.tier) == ("block", "P")
        assert "protected" in d.reason


def test_configured_protected_objects_and_list_identities():
    s = Settings(protected_objects=("svc-sql",))
    assert decide(GROUP, {"group": "Staff", "members": ["amy", "SVC-SQL"]}, s).tier == "P"


def test_privileged_group_escalates_to_high():
    assert decide(GROUP, {"group": "Domain Admins", "members": ["bob"]}, STRICT).tier == "H"
    assert decide(GROUP, {"group": "CN=Enterprise Admins,CN=Users,DC=corp", "members": ["bob"]}, PERMISSIVE).action == "approve"
    assert decide(GROUP, {"group": "Finance-RW", "members": ["bob"]}, PERMISSIVE).action == "allow"
    assert decide(GROUP, {"group": "Tier0", "members": ["bob"]}, Settings(privileged_groups=("Tier0",))).tier == "H"


def test_normalize_identity_strips_dn_domain_and_upn():
    assert normalize_identity("CN=Bob Smith,OU=Staff,DC=corp") == "bob smith"
    assert normalize_identity("CORP\\bob") == "bob"
    assert normalize_identity("bob@corp.local") == "bob"


def test_is_domain_controller_name_matches_short_or_fqdn():
    assert is_domain_controller_name("dc01.corp.local", ["DC01"])
    assert is_domain_controller_name("DC02", ["dc02.corp.local"])
    assert not is_domain_controller_name("srv-app02", ["DC01"])
