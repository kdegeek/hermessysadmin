import pytest

from sysadmin.errors import InvalidArguments
from sysadmin.registry import OPS, Op, Param, coerce_args, ps_params, register, schema_for, target_of

OP = Op(
    name="t_reg_unlock",
    toolset="t",
    tier="W",
    script="t_reg_unlock",
    description="Unlock a user.",
    params=(
        Param("identity", "string", "sAMAccountName", required=True),
        Param("days", "integer", "Days", minimum=1, default=30),
        Param("force", "boolean", "Force"),
        Param("hosts", "array", "Hosts"),
        Param("kind", "string", "Kind", enum=("user", "group")),
        Param("ou_dn", "string", "OU", ps="SearchBase"),
    ),
)


def test_param_ps_name_is_camel_case_unless_overridden():
    assert Param("new_password", "string", "x").ps_name == "NewPassword"
    assert Param("ou_dn", "string", "x", ps="SearchBase").ps_name == "SearchBase"


def test_schema_for_is_openai_style_with_tier_label():
    schema = schema_for(OP)
    assert schema["name"] == "t_reg_unlock"
    assert schema["description"].startswith("[write · needs approval] ")
    params = schema["parameters"]
    assert params["required"] == ["identity"]
    assert params["additionalProperties"] is False
    assert params["properties"]["days"] == {"type": "integer", "description": "Days", "default": 30, "minimum": 1}
    assert params["properties"]["hosts"]["items"] == {"type": "string"}
    assert params["properties"]["kind"]["enum"] == ["user", "group"]


def test_coerce_args_applies_defaults_and_coerces_types():
    out = coerce_args(OP, {"identity": " bob ", "force": "true", "hosts": "a, b", "days": "5"})
    assert out == {"identity": "bob", "days": 5, "force": True, "hosts": ["a", "b"]}


@pytest.mark.parametrize(
    "args, message",
    [
        ({}, "'identity' is required"),
        ({"identity": "   "}, "'identity' is required"),
        ({"identity": "b", "nope": 1}, "Unknown argument"),
        ({"identity": "b", "days": 0}, "must be ≥ 1"),
        ({"identity": "b", "days": True}, "must be an integer"),
        ({"identity": "b", "days": "--5"}, "must be an integer"),
        ({"identity": "b", "days": "²"}, "must be an integer"),
        ({"identity": "b", "force": "maybe"}, "true or false"),
        ({"identity": "b", "kind": "ou"}, "must be one of"),
        ({"identity": "b", "hosts": [1]}, "list of strings"),
        ({"identity": ["b"]}, "must be a string"),
    ],
)
def test_coerce_args_rejects_bad_input(args, message):
    with pytest.raises(InvalidArguments, match=message):
        coerce_args(OP, args)


def test_ps_params_maps_names():
    assert ps_params(OP, {"identity": "bob", "ou_dn": "OU=X", "days": 3}) == {
        "Identity": "bob", "SearchBase": "OU=X", "Days": 3,
    }


def test_target_of_uses_target_fn_or_first_required_param():
    assert target_of(OP, {"identity": "bob"}) == "bob"
    op = Op("t_x", "t", "R", "t_x", "d", target=lambda a: f"{a['g']} ← {a['m']}")
    assert target_of(op, {"g": "Admins", "m": "bob"}) == "Admins ← bob"


def test_register_rejects_duplicates_bad_tier_and_read_preview(scratch_ops):
    scratch_ops(Op("t_reg_once", "t", "R", "t_reg_once", "d"))
    with pytest.raises(ValueError):
        register(Op("t_reg_once", "t", "R", "t_reg_once", "d"))
    with pytest.raises(ValueError):
        register(Op("t_reg_bad", "t", "X", "t_reg_bad", "d"))
    with pytest.raises(ValueError):
        register(Op("t_reg_prev", "t", "R", "t_reg_prev", "d", preview=True))
    assert "t_reg_once" in OPS
