import sqlite3

from sysadmin.audit import AuditLog, open_audit, redact


def make():
    return AuditLog(sqlite3.connect(":memory:", check_same_thread=False))


def test_redact_hides_password_keys_only():
    assert redact({"identity": "bob", "password": "x", "New_Password": "y"}) == {
        "identity": "bob", "password": "[redacted]", "New_Password": "[redacted]",
    }


def test_record_and_query_newest_first_with_redaction():
    log = make()
    log.record(actor="agent", session="s1", tool="ad_user_unlock", target="bob", tier="W", decision="approved", result="ok", params={"identity": "bob"})
    log.record(actor="dashboard", session="", tool="ad_user_reset_password", target="amy", tier="W", decision="confirmed", result="ok", params={"identity": "amy", "password": "secret"})
    rows = log.query()
    assert [r["tool"] for r in rows] == ["ad_user_reset_password", "ad_user_unlock"]
    assert rows[0]["params"] == {"identity": "amy", "password": "[redacted]"}
    assert rows[0]["ts"].endswith("+00:00")
    assert "secret" not in str(rows)


def test_query_filters_by_actor_and_decision_prefix_and_limit():
    log = make()
    for i in range(5):
        log.record(actor="agent", session="", tool=f"t{i}", target="", tier="W", decision="approved", result="ok", params={})
    log.record(actor="agent", session="", tool="x", target="krbtgt", tier="P", decision="blocked: protected", result="-", params={})
    log.record(actor="dashboard", session="", tool="y", target="", tier="W", decision="confirmed", result="ok", params={})
    assert [r["tool"] for r in log.query(decision="blocked")] == ["x"]
    assert [r["tool"] for r in log.query(actor="dashboard")] == ["y"]
    assert len(log.query(limit=2)) == 2


def test_long_results_are_truncated():
    log = make()
    log.record(actor="agent", session="", tool="t", target="", tier="W", decision="approved", result="e" * 2000, params={})
    assert len(log.query()[0]["result"]) == 500


def test_open_audit_without_hermes_uses_memory_db():
    log = open_audit()
    log.record(actor="agent", session="", tool="t", target="", tier="W", decision="approved", result="ok", params={})
    assert log.query()[0]["tool"] == "t"



def test_oversized_params_stay_valid_json():
    log = make()
    log.record(actor="agent", session="", tool="ad_powershell", target="", tier="H", decision="approved", result="ok", params={"script": "x" * 30000})
    params = log.query()[0]["params"]
    assert set(params) == {"_truncated"} and len(params["_truncated"]) < 24000


def test_redact_recurses_and_normalizes_keys():
    out = redact({
        "newPassword": "a", "Old-Password": "b", "nested": {"SecurePassword": "c", "ok": 1},
        "items": [{"pwd": "d"}, ({"user_password": "e"},)], 5: "x", "plain": "v",
    })
    assert out["newPassword"] == "[redacted]" and out["Old-Password"] == "[redacted]"
    assert out["nested"] == {"SecurePassword": "[redacted]", "ok": 1}
    assert out["items"][0] == {"pwd": "[redacted]"}
    assert out["items"][1][0] == {"user_password": "[redacted]"}
    assert out["5"] == "x" and out["plain"] == "v"


def test_oversized_params_with_password_stay_redacted():
    log = open_audit()
    log.record(actor="a", session="", tool="t", target="", tier="W", decision="allow", result="ok",
               params={"blob": "z" * 10000, "nested": {"password": "hunter2"}})
    row = log.query()[0]
    assert "hunter2" not in str(row["params"])
