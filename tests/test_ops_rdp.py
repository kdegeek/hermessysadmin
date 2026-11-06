import pytest

from sysadmin import ops  # noqa: F401
from sysadmin.config import Settings
from sysadmin.ops.rdp import host_warnings, idle_minutes, parse_quser, rdp_file, rdp_uri
from sysadmin.policy import decide
from sysadmin.registry import OPS, ps_params

EXPECTED = {
    "rdp_sessions": ("R", False), "rdp_host_status": ("R", False), "rdp_connect_file": ("R", False),
    "rdp_session_logoff": ("W", True), "rdp_session_disconnect": ("W", False), "rdp_session_message": ("W", False),
    "rdp_set_enabled": ("W", True), "rdp_set_nla": ("W", False),
    "rdp_users_add": ("W", False), "rdp_users_remove": ("W", False),
}

QUSER = [
    " USERNAME              SESSIONNAME        ID  STATE   IDLE TIME  LOGON TIME",
    " alice                 rdp-tcp#12          2  Active          .  11/4/2026 8:01 AM",
    " bob                                       3  Disc         1:02  11/3/2026 4:15 PM",
    ">carol                 console             1  Active       none  11/1/2026 9:00 AM",
    " dave                  rdp-tcp#14          4  Active    2+03:04  10/31/2026 7:30 AM",
]


class DCs:
    def __init__(self, names):
        self.names = names

    def domain_controllers(self):
        return self.names


DC = DCs(["DC01.corp.local"])


@pytest.mark.parametrize("name", sorted(EXPECTED))
def test_tiers(name):
    assert (OPS[name].tier, OPS[name].preview) == EXPECTED[name]
    assert OPS[name].toolset == "ad_rdp"


def test_parse_quser():
    rows = parse_quser(QUSER)
    assert [(r["user"], r["session"], r["id"], r["state"], r["idle_minutes"]) for r in rows] == [
        ("alice", "rdp-tcp#12", 2, "active", 0),
        ("bob", "", 3, "disconnected", 62),
        ("carol", "console", 1, "active", 0),
        ("dave", "rdp-tcp#14", 4, "active", 3064),
    ]
    assert rows[1]["logon"] == "11/3/2026 4:15 PM"


def test_parse_quser_ignores_no_user_message():
    assert parse_quser(["No User exists for *"]) == []


@pytest.mark.parametrize(
    "text, minutes",
    [(".", 0), ("none", 0), ("45", 45), ("1:02", 62), ("2+03:04", 3064), ("garbage", None)],
)
def test_idle_minutes(text, minutes):
    assert idle_minutes(text) == minutes


def test_sessions_post_flattens_and_summarises():
    data = {
        "hosts": [{"host": "SRV1", "lines": QUSER}, {"host": "SRV2", "lines": ["No User exists for *"]}],
        "errors": [{"host": "SRV3", "message": "WinRM cannot complete the operation"}],
    }
    out = OPS["rdp_sessions"].post(data, {}, Settings())
    assert len(out["items"]) == 4 and out["items"][0]["host"] == "SRV1"
    assert out["summary"] == {"hosts": 3, "reachable": 2, "sessions": 4, "active": 3, "disconnected": 1, "idle_over_60": 2}
    assert out["errors"][0]["host"] == "SRV3"


def test_sessions_post_filters_by_user_ignoring_domain_prefix():
    data = {"hosts": [{"host": "SRV1", "lines": QUSER}], "errors": []}
    out = OPS["rdp_sessions"].post(data, {"user": "CORP\\BOB"}, Settings())
    assert [i["user"] for i in out["items"]] == ["bob"]
    assert out["summary"]["sessions"] == 1


@pytest.mark.parametrize(
    "host, warnings",
    [
        ({"enabled": True, "nla": False, "firewall_open": True}, ["RDP enabled without Network Level Authentication"]),
        ({"enabled": True, "nla": True, "firewall_open": False}, ["RDP enabled but the Remote Desktop firewall rules are disabled"]),
        ({"enabled": False, "nla": False, "firewall_open": False}, []),
    ],
)
def test_host_warnings(host, warnings):
    assert host_warnings(host) == warnings


def test_host_status_post():
    data = {
        "results": [
            {"host": "B", "enabled": False, "nla": True, "firewall_open": False},
            {"host": "A", "enabled": True, "nla": False, "firewall_open": True},
        ],
        "errors": [{"host": "C", "message": "unreachable"}],
    }
    out = OPS["rdp_host_status"].post(data, {}, Settings())
    assert [h["host"] for h in out["items"]] == ["A", "B"]
    assert out["items"][0]["warnings"] == ["RDP enabled without Network Level Authentication"]
    assert out["summary"] == {"hosts": 3, "enabled": 1, "nla_off": 1, "unreachable": 1}


def test_set_enabled_escalates_on_dcs_and_when_dcs_unknown():
    s = Settings()
    op = OPS["rdp_set_enabled"]
    assert decide(op, {"hosts": ["dc01"], "enabled": True}, s, DC).tier == "H"
    assert decide(op, {"hosts": ["srv1.corp.local"], "enabled": True}, s, DC).tier == "W"
    assert decide(op, {"hosts": ["srv1.corp.local"], "enabled": True}, s, DCs(None)).tier == "H"


def test_disabling_nla_escalates():
    s = Settings()
    assert decide(OPS["rdp_set_nla"], {"hosts": ["srv1"], "required": False}, s, DC).tier == "H"
    assert decide(OPS["rdp_set_nla"], {"hosts": ["srv1"], "required": True}, s, DC).tier == "W"


def test_rdp_users_on_dc_escalate():
    s = Settings()
    for name in ("rdp_users_add", "rdp_users_remove"):
        assert decide(OPS[name], {"host": "DC01.corp.local", "members": ["alice"]}, s, DC).tier == "H"
        assert decide(OPS[name], {"host": "srv1", "members": ["alice"]}, s, DC).tier == "W"


def test_session_ops_do_not_escalate():
    s = Settings()
    for name in ("rdp_session_logoff", "rdp_session_disconnect", "rdp_session_message"):
        assert decide(OPS[name], {"host": "dc01", "session_id": 2, "message": "hi"}, s, DC).tier == "W"


def test_rdp_file_and_uri():
    text = rdp_file("srv1.corp.local", "CORP\\alice", "rdgw.corp.example")
    assert text.endswith("\r\n")
    lines = text.split("\r\n")
    assert "full address:s:srv1.corp.local" in lines
    assert "username:s:CORP\\alice" in lines
    assert "gatewayhostname:s:rdgw.corp.example" in lines
    assert rdp_uri("srv1.corp.local", "CORP\\alice") == "rdp://full%20address=s:srv1.corp.local&username=s:CORP%5Calice"


def test_rdp_file_strips_line_breaks():
    text = rdp_file("srv1", "alice\r\nalternate shell:s:cmd.exe")
    assert "alternate shell:s:cmd.exe" not in text.split("\r\n")


def test_connect_file_post():
    out = OPS["rdp_connect_file"].post({"host": "SRV1.corp.local"}, {"host": "srv1", "username": "alice"}, Settings())
    assert out["filename"] == "srv1.rdp"
    assert out["uri"] == "rdp://full%20address=s:SRV1.corp.local&username=s:alice"
    assert "full address:s:SRV1.corp.local" in out["content"]


def test_host_maps_to_computer_name_and_search_base_is_injected():
    assert ps_params(OPS["rdp_session_logoff"], {"host": "SRV1", "session_id": 3}) == {"ComputerName": "SRV1", "SessionId": 3}
    s = Settings(server_search_base="OU=Servers,DC=corp,DC=local")
    for name in ("rdp_sessions", "rdp_host_status"):
        assert OPS[name].inject(s) == {"ServerSearchBase": "OU=Servers,DC=corp,DC=local"}


@pytest.mark.parametrize("dcs", [None, []])
def test_unknown_or_empty_dc_list_escalates(dcs):
    assert decide(OPS["rdp_set_enabled"], {"hosts": ["srv1"], "enabled": True}, Settings(), DCs(dcs)).tier == "H"
    assert decide(OPS["rdp_users_add"], {"host": "srv1", "members": ["a"]}, Settings(), DCs(dcs)).tier == "H"


@pytest.mark.parametrize("host", ["10.0.0.5", "::1", "fe80::1", "2001:db8::1", "localhost", "LOCALHOST", ".", "127.0.0.1"])
def test_ip_literals_and_loopback_escalate(host):
    assert decide(OPS["rdp_set_enabled"], {"hosts": [host], "enabled": True}, Settings(), DC).tier == "H"
    assert decide(OPS["rdp_users_remove"], {"host": host, "members": ["a"]}, Settings(), DC).tier == "H"


@pytest.mark.parametrize("hosts", [["srv1", 5], ["srv1", None], "srv1", {"a": "b"}, 7])
def test_malformed_hosts_escalate(hosts):
    assert decide(OPS["rdp_set_enabled"], {"hosts": hosts, "enabled": True}, Settings(), DC).tier == "H"


def test_empty_string_hosts_are_dropped():
    assert decide(OPS["rdp_set_enabled"], {"hosts": ["", "srv1"], "enabled": True}, Settings(), DC).tier == "W"


def test_connect_filename_sanitised():
    f = OPS["rdp_connect_file"].post
    assert f({"host": "../evil"}, {}, Settings())["filename"] == "rdp-host.rdp"
    assert f({"host": "a/b c.corp"}, {}, Settings())["filename"] == "a_b_c.rdp"
    assert f({"host": ""}, {}, Settings())["filename"] == "rdp-host.rdp"
    assert f({"host": "///"}, {}, Settings())["filename"] == "___.rdp"


def test_quser_maps_disconnected_word():
    rows = parse_quser([" bob  4  Disconnected  1:02  11/3/2026 4:15 PM"])
    assert rows[0]["state"] == "disconnected"


@pytest.mark.parametrize("wanted", ["bob@corp.local", "CORP\\bob", "BOB@CORP"])
def test_sessions_user_filter_strips_upn_and_domain(wanted):
    data = {"hosts": [{"host": "SRV1", "lines": QUSER}], "errors": []}
    out = OPS["rdp_sessions"].post(data, {"user": wanted}, Settings())
    assert [i["user"] for i in out["items"]] == ["bob"]
