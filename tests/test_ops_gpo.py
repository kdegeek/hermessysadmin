import pytest

from sysadmin import ops  # noqa: F401
from sysadmin.config import Settings
from sysadmin.ops.gpo import gpo_issues, is_default_policy, is_wide_scope
from sysadmin.policy import decide
from sysadmin.registry import OPS

EXPECTED = {
    "gpo_list": ("R", False), "gpo_health": ("R", False), "gpo_get": ("R", False), "gpo_report": ("R", False),
    "gpo_rsop": ("R", False), "gpo_backups": ("R", False),
    "gpo_create": ("W", False), "gpo_backup": ("W", False), "gpo_update_hosts": ("W", False),
    "gpo_link": ("W", True), "gpo_unlink": ("W", True), "gpo_set_link": ("W", True),
    "gpo_set_status": ("W", False), "gpo_set_security_filter": ("W", False),
    "gpo_delete": ("H", True), "gpo_restore": ("H", True),
}

GOOD = {
    "status": "AllSettingsEnabled",
    "links": [{"target": "OU=Staff,DC=corp", "enabled": True, "enforced": False, "order": 1}],
    "user_version": {"ad": 3, "sysvol": 3},
    "computer_version": {"ad": 5, "sysvol": 5},
}


@pytest.mark.parametrize("name", sorted(EXPECTED))
def test_tiers(name):
    assert (OPS[name].tier, OPS[name].preview) == EXPECTED[name]
    assert OPS[name].toolset == "ad_gpo"


@pytest.mark.parametrize(
    "changes, issue",
    [
        ({"links": []}, "Unlinked"),
        ({"links": [{"target": "OU=X", "enabled": False}]}, "All links disabled"),
        ({"status": "AllSettingsDisabled"}, "All settings disabled"),
        ({"user_version": {"ad": 0, "sysvol": 0}, "computer_version": {"ad": 0, "sysvol": 0}}, "Empty (no settings)"),
        ({"computer_version": {"ad": 14, "sysvol": 12}}, "Version mismatch: computer AD 14 / SYSVOL 12"),
        ({"user_version": {"ad": 2, "sysvol": 1}}, "Version mismatch: user AD 2 / SYSVOL 1"),
    ],
)
def test_gpo_issues(changes, issue):
    assert issue in gpo_issues({**GOOD, **changes})


def test_healthy_gpo_has_no_issues():
    assert gpo_issues(GOOD) == []


def test_list_and_health_posts():
    data = {"items": [{**GOOD, "name": "A"}, {**GOOD, "name": "B", "links": []}]}
    listed = OPS["gpo_list"].post(data, {}, Settings())
    assert [g["health"] for g in listed["items"]] == [[], ["Unlinked"]]
    assert listed["summary"] == {"total": 2, "needs_attention": 1, "unlinked": 1}
    health = OPS["gpo_health"].post(data, {}, Settings())
    assert [g["name"] for g in health["items"]] == ["B"]
    assert OPS["gpo_health"].script == "gpo_list"


@pytest.mark.parametrize(
    "dn, wide",
    [
        ("DC=corp,DC=example,DC=local", True),
        ("OU=Domain Controllers,DC=corp,DC=local", True),
        ("CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=corp,DC=local", True),
        ("OU=Finance,OU=Staff,DC=corp,DC=local", False),
    ],
)
def test_is_wide_scope(dn, wide):
    assert is_wide_scope(dn) is wide


def test_link_escalates_for_wide_scope_only():
    s = Settings()
    assert decide(OPS["gpo_link"], {"identity": "Lock", "target": "DC=corp,DC=local"}, s).tier == "H"
    assert decide(OPS["gpo_link"], {"identity": "Lock", "target": "OU=Finance,DC=corp,DC=local"}, s).tier == "W"
    assert decide(OPS["gpo_unlink"], {"identity": "Lock", "target": "OU=Domain Controllers,DC=corp,DC=local"}, s).tier == "H"


def test_default_policies_escalate_status_and_filter_changes():
    s = Settings()
    assert is_default_policy("{31B2F340-016D-11D2-945F-00C04FB984F9}")
    assert is_default_policy("Default Domain Controllers Policy")
    assert decide(OPS["gpo_set_status"], {"identity": "Default Domain Policy", "status": "AllSettingsDisabled"}, s).tier == "H"
    assert decide(OPS["gpo_set_security_filter"], {"identity": "Finance Maps", "add": ["Finance"]}, s).tier == "W"


def test_protected_gpo_names_block_changes():
    s = Settings(protected_objects=("Workstation Baseline",))
    assert decide(OPS["gpo_delete"], {"identity": "workstation baseline"}, s).tier == "P"


@pytest.mark.parametrize(
    "dn",
    [
        "DC = corp,DC=local",
        " dc=corp, dc=local",
        "OU=Domain Controllers ,DC=corp,DC=local",
        "OU = Domain Controllers,DC=corp,DC=local",
        "CN=Default-First-Site-Name, CN=Sites,CN=Configuration,DC=corp,DC=local",
        "CN=Default-First-Site-Name,CN=Sites ,CN=Configuration,DC=corp,DC=local",
    ],
)
def test_wide_scope_tolerates_dn_whitespace(dn):
    assert is_wide_scope(dn)


def test_narrow_scope_is_not_wide():
    assert not is_wide_scope("OU=Sales,DC=corp,DC=local")
    assert not is_wide_scope("OU=Domain Controllers Archive,OU=Old,DC=corp,DC=local")


@pytest.mark.parametrize(
    "identity",
    [
        "{ 31B2F340-016D-11D2-945F-00C04FB984F9 }",
        "cn={6AC1786C-016F-11D2-945F-00C04fB984F9},cn=policies,cn=system,dc=corp,dc=local",
        "Default  Domain   Policy",
    ],
)
def test_default_policy_spellings(identity):
    assert is_default_policy(identity)
