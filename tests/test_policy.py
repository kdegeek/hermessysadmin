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
    for settings in (STRICT, PERMISSIVE, READONLY):
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


@pytest.mark.parametrize("ident", [
    "CN = krbtgt,CN=Users,DC=corp", "  cn=krbtgt,CN=Users,DC=corp", "cn =Administrator,CN=Users",
    "S-1-5-21-1-2-3-500", "s-1-5-21-111-222-333-502",
])
def test_dn_spacing_case_and_sid_forms_are_protected(ident):
    d = decide(WRITE, {"identity": ident}, PERMISSIVE)
    assert (d.action, d.tier) == ("block", "P")


def test_normalize_identity_dn_variants():
    assert normalize_identity("CN = krbtgt,CN=Users,DC=corp") == "krbtgt"
    assert normalize_identity("CN=Smith\\, John,OU=x") == "smith, john"


def test_escaped_comma_dn_can_be_configured_protected():
    s = Settings(protected_objects=("Smith, John",))
    assert decide(WRITE, {"identity": "CN=Smith\\, John,OU=x"}, s).tier == "P"


def test_non_protected_sid_is_not_blocked():
    assert decide(WRITE, {"identity": "S-1-5-21-1-2-3-1104"}, STRICT).action == "approve"


@pytest.mark.parametrize("value", [("amy", "krbtgt"), {"krbtgt"}, ("amy", 5), [1], [{"a": 1}], ["amy", ["krbtgt"]], ["amy", None], 7, {"a": 1}])
def test_uninterpretable_identities_fail_closed(value):
    d = decide(GROUP, {"group": "Staff", "members": value}, PERMISSIVE)
    assert d.action == "block"
    assert d.tier == "P"


def test_tuple_with_protected_member_blocks():
    d = decide(GROUP, {"group": "Staff", "members": ("amy", "KRBTGT")}, PERMISSIVE)
    assert (d.action, d.tier) == ("block", "P")


def test_missing_or_none_identity_keeps_prior_behavior():
    assert decide(WRITE, {}, STRICT).action == "approve"
    assert decide(WRITE, {"identity": None}, STRICT).action == "approve"


def test_read_with_protected_identity_stays_allowed():
    assert decide(READ, {"identity": "krbtgt"}, STRICT).action == "allow"


def test_high_without_preview_flag_needs_no_preview():
    h = Op("t_p_high2", "t", "H", "t", "d", params=(Param("identity", "string", "x"),), identities=("identity",), preview=False)
    d = decide(h, {"identity": "bob"}, STRICT)
    assert d.action == "approve" and d.needs_preview is False


def test_escalate_exception_fails_closed():
    def boom(args, settings, facts):
        raise KeyError("group")
    op = Op("t_p_boom", "t", "W", "t", "d", params=(Param("identity", "string", "x"),), identities=("identity",), escalate=boom)
    d = decide(op, {"identity": "bob"}, PERMISSIVE)
    assert d.action == "block"
    assert "safety check failed" in d.reason


def test_privileged_group_in_spaced_dn_and_sid_escalates():
    assert decide(GROUP, {"group": "CN = Domain Admins,CN=Users,DC=corp", "members": ["bob"]}, PERMISSIVE).tier == "H"
    assert decide(GROUP, {"group": "S-1-5-32-544", "members": ["bob"]}, PERMISSIVE).tier == "H"


@pytest.mark.parametrize(
    "dn",
    [
        r"CN=\6brbtgt,CN=Users,DC=corp,DC=local",
        'CN="krbtgt",CN=Users,DC=corp,DC=local',
        "CN=krbtgt+OU=x,CN=Users,DC=corp,DC=local",
        r'CN="krb\74gt",CN=Users,DC=corp,DC=local',
    ],
)
def test_dn_escape_quote_and_multivalue_forms_normalize(dn):
    assert normalize_identity(dn) == "krbtgt"


def test_audit_record_accepts_non_string_keys():
    import sqlite3
    from sysadmin.audit import AuditLog
    log = AuditLog(sqlite3.connect(":memory:", check_same_thread=False))
    log.record(actor="agent", session="", tool="t", target="", tier="W", decision="approved", result="ok", params={("a", 1): 2, b"k": 3})
    assert log.query()[0]["params"] == {"('a', 1)": 2, "b'k'": 3}


@pytest.mark.parametrize(
    "group",
    [
        "S-1-5-21-1111-2222-3333-512",
        "s-1-5-21-1-2-3-519",
        "S-1-5-32-544",
        "S-1-5-32-551",
        "6f9619ff-8b86-d011-b42d-00c04fc964ff",
        "{6F9619FF-8B86-D011-B42D-00C04FC964FF}",
    ],
)
def test_privileged_group_sid_and_guid_forms(group):
    from sysadmin.policy import is_privileged_group

    assert is_privileged_group(group, Settings())


def test_ordinary_group_sid_is_not_privileged():
    from sysadmin.policy import is_privileged_group

    assert not is_privileged_group("S-1-5-21-1111-2222-3333-1105", Settings())
