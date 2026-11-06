import pytest

from sysadmin import ops  # noqa: F401
from sysadmin.config import Settings
from sysadmin.ops.users import privileged_group_names
from sysadmin.policy import decide
from sysadmin.registry import OPS, coerce_args

EXPECTED = {
    "ad_user_get": ("R", False), "ad_user_list": ("R", False), "ad_lockout_source": ("R", False),
    "ad_group_get": ("R", False), "ad_group_list": ("R", False), "ad_recycle_bin_list": ("R", False),
    "ad_user_create": ("W", False), "ad_user_update": ("W", False), "ad_user_reset_password": ("W", False),
    "ad_user_unlock": ("W", False), "ad_user_enable": ("W", False), "ad_user_disable": ("W", False),
    "ad_user_move": ("W", False), "ad_group_add_member": ("W", True), "ad_group_remove_member": ("W", True),
    "ad_recycle_bin_restore": ("W", False), "ad_user_delete": ("H", True),
}


@pytest.mark.parametrize("name", sorted(EXPECTED))
def test_tier_preview_and_toolset(name):
    op = OPS[name]
    assert (op.tier, op.preview) == EXPECTED[name]
    assert op.toolset == "ad_users"


def test_group_change_escalates_only_for_privileged_groups():
    s = Settings()
    op = OPS["ad_group_add_member"]
    assert decide(op, {"group": "Domain Admins", "members": ["bob"]}, s).tier == "H"
    assert decide(op, {"group": "Finance-RW", "members": ["bob"]}, s).tier == "W"
    assert decide(OPS["ad_group_remove_member"], {"group": "Schema Admins", "members": ["bob"]}, s).tier == "H"


def test_protected_accounts_blocked_on_user_and_group_ops():
    s = Settings(protected_objects=("ceo",))
    assert decide(OPS["ad_user_reset_password"], {"identity": "Administrator"}, s).tier == "P"
    assert decide(OPS["ad_user_create"], {"sam": "krbtgt"}, s).tier == "P"
    assert decide(OPS["ad_group_add_member"], {"group": "Staff", "members": ["CEO"]}, s).tier == "P"
    assert decide(OPS["ad_user_disable"], {"identity": "amy"}, s).action == "approve"


def test_group_targets_are_readable():
    from sysadmin.registry import target_of

    assert target_of(OPS["ad_group_add_member"], {"group": "Admins", "members": ["a", "b"]}) == "Admins ← a, b"
    assert target_of(OPS["ad_group_remove_member"], {"group": "Admins", "members": ["a"]}) == "Admins → a"


def test_create_injects_privileged_groups_including_configured():
    names = privileged_group_names(Settings(privileged_groups=("Tier0",)))
    assert "domain admins" in names and "tier0" in names
    assert OPS["ad_user_create"].inject(Settings())["PrivilegedGroups"] == privileged_group_names(Settings())


def test_user_get_post_flags_privileged():
    post = OPS["ad_user_get"].post
    assert post({"sam": "a", "groups": ["Staff", "Domain Admins"]}, {}, Settings())["privileged"] is True
    assert post({"sam": "b", "groups": ["Staff"]}, {}, Settings())["privileged"] is False


def test_user_list_post_filters_privileged_and_limits():
    post = OPS["ad_user_list"].post
    data = {"items": [{"sam": "a", "groups": ["Domain Admins"]}, {"sam": "b", "groups": []}, {"sam": "c", "groups": ["Backup Operators"]}], "total": 3}
    out = post(data, {"privileged": True, "limit": 1}, Settings())
    assert [u["sam"] for u in out["items"]] == ["a"]
    assert out["total"] == 2
    out = post(data, {"privileged": False, "limit": 200}, Settings())
    assert out["total"] == 3 and [u["privileged"] for u in out["items"]] == [True, False, True]


def test_lockout_post_ranks_sources():
    post = OPS["ad_lockout_source"].post
    out = post({"events": [{"source": "SRV-APP02"}, {"source": "WS-1"}, {"source": "SRV-APP02"}, {"source": ""}]}, {}, Settings())
    assert out["sources"] == [{"source": "SRV-APP02", "count": 2}, {"source": "(unknown)", "count": 1}, {"source": "WS-1", "count": 1}]
    assert out["likely_source"] == "SRV-APP02"
    assert post({"events": []}, {}, Settings())["likely_source"] is None


def test_user_list_defaults():
    assert coerce_args(OPS["ad_user_list"], {}) == {
        "status": "any", "password": "any", "expiring_days": 7, "privileged": False, "limit": 200,
    }
