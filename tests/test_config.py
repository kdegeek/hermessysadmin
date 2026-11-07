from sysadmin import config
from sysadmin.config import Settings, load_settings, settings_from


def test_defaults_when_empty():
    s = settings_from({}, "")
    assert s == Settings()
    assert not s.configured


def test_parses_and_coerces_values():
    s = settings_from(
        {
            "host": " dc01.corp.local ",
            "port": "5985",
            "use_https": "false",
            "auth": "KERBEROS",
            "username": "CORP\\svc",
            "mode": "permissive",
            "protected_objects": "svc-sql, ceo\n",
            "privileged_groups": ["Tier0"],
            "backup_stale_days": "3",
            "enable_powershell_escape": "yes",
            "verify_tls": False,
            "server_search_base": "OU=Servers,DC=corp,DC=local",
        },
        "pw",
    )
    assert s.host == "dc01.corp.local"
    assert s.port == 5985 and s.use_https is False and s.auth == "kerberos"
    assert s.mode == "permissive"
    assert s.protected_objects == ("svc-sql", "ceo")
    assert s.privileged_groups == ("Tier0",)
    assert s.backup_stale_days == 3
    assert s.enable_powershell_escape is True and s.verify_tls is False
    assert s.server_search_base == "OU=Servers,DC=corp,DC=local"
    assert s.configured


def test_invalid_values_fall_back_to_defaults():
    s = settings_from({"port": "99999", "mode": "yolo", "auth": "basic", "backup_stale_days": "-1"}, "")
    assert (s.port, s.mode, s.auth, s.backup_stale_days) == (5986, "strict", "ntlm", 7)


def test_http_default_port_is_5985():
    assert settings_from({"use_https": False}, "").port == 5985


def test_password_not_in_repr():
    assert "hunter2" not in repr(settings_from({}, "hunter2"))


def test_load_settings_without_hermes_returns_defaults(monkeypatch):
    monkeypatch.setattr(config, "_plugin_settings", lambda: {"host": "dc01"})
    monkeypatch.setattr(config, "_password", lambda: "pw")
    s = load_settings()
    assert s.host == "dc01" and s.password == "pw"


def test_load_settings_never_raises(monkeypatch):
    def boom():
        raise RuntimeError("config broken")

    monkeypatch.setattr(config, "_plugin_settings", boom)
    assert load_settings() == Settings()


# --- Task 17: transport and run_as -------------------------------------------------------

import pytest


def _no_join(monkeypatch, nt=False, joined=False):
    monkeypatch.setattr(config, "_os_name", lambda: "nt" if nt else "posix")
    monkeypatch.setattr(config, "_domain_joined", lambda: joined)


def test_transport_and_run_as_defaults(monkeypatch):
    _no_join(monkeypatch)
    s = settings_from({}, "")
    assert s.transport == "winrm" and s.run_as == "account"


@pytest.mark.parametrize("nt,joined,expected", [
    (True, True, "local"), (True, False, "winrm"), (False, True, "winrm"), (False, False, "winrm"),
])
def test_auto_transport_resolves_from_os_and_domain_join(monkeypatch, nt, joined, expected):
    _no_join(monkeypatch, nt=nt, joined=joined)
    assert settings_from({"transport": "auto"}, "").transport == expected
    assert settings_from({}, "").transport == expected


def test_explicit_transport_wins_over_auto(monkeypatch):
    _no_join(monkeypatch, nt=True, joined=True)
    assert settings_from({"transport": "WinRM"}, "").transport == "winrm"
    _no_join(monkeypatch)
    assert settings_from({"transport": "local"}, "").transport == "local"


def test_unknown_transport_and_run_as_fall_back(monkeypatch):
    _no_join(monkeypatch)
    s = settings_from({"transport": "ssh", "run_as": "root"}, "")
    assert s.transport == "winrm" and s.run_as == "account"
    assert settings_from({"run_as": "Hermes_User"}, "").run_as == "hermes_user"


def test_domain_join_check_is_false_off_windows(monkeypatch):
    monkeypatch.setattr(config, "_os_name", lambda: "posix")
    config._domain_joined.cache_clear()
    assert config._domain_joined() is False
    config._domain_joined.cache_clear()


@pytest.mark.parametrize("transport,run_as,host,user,pw,expected", [
    ("winrm", "account", "dc01", "u", "p", True),
    ("winrm", "hermes_user", "dc01", "u", "p", True),
    ("winrm", "account", "", "u", "p", False),
    ("winrm", "account", "dc01", "", "p", False),
    ("winrm", "account", "dc01", "u", "", False),
    ("winrm", "hermes_user", "", "", "", False),
    ("local", "hermes_user", "", "", "", True),
    ("local", "account", "", "u", "p", True),
    ("local", "account", "", "u", "", False),
    ("local", "account", "", "", "p", False),
])
def test_configured_matrix(transport, run_as, host, user, pw, expected):
    s = Settings(transport=transport, run_as=run_as, host=host, username=user, password=pw)
    assert s.configured is expected
