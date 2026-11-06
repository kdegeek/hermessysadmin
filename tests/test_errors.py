from sysadmin.errors import (
    ERROR_TYPES,
    ConnectionFailed,
    NotFound,
    PermissionDenied,
    error_result,
)


def test_error_result_includes_type_message_hint_and_non_empty_details():
    result = error_result(NotFound("No user bob", target="bob", category=""))
    assert result == {
        "ok": False,
        "error": {
            "type": "NotFound",
            "message": "No user bob",
            "hint": NotFound.default_hint,
            "target": "bob",
        },
    }


def test_custom_hint_overrides_default():
    assert PermissionDenied("x", hint="ask Ada").to_dict()["hint"] == "ask Ada"


def test_unknown_exception_becomes_internal_error():
    result = error_result(ValueError("boom"))
    assert result["ok"] is False
    assert result["error"]["type"] == "InternalError"
    assert "boom" in result["error"]["message"]


def test_error_types_are_indexed_by_type_string():
    assert ERROR_TYPES["NotFound"] is NotFound
    assert ERROR_TYPES["ConnectionError"] is ConnectionFailed
    assert set(ERROR_TYPES) == {
        "NotConfigured", "ConnectionError", "PermissionDenied", "NotFound", "PolicyBlocked",
        "ApprovalRequired", "RemoteScriptError", "Timeout", "InvalidArguments", "NotInstalled", "PartialResult",
    }
