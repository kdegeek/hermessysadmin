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
