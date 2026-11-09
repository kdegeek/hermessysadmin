from sysadmin import catalog, collector, config


def test_collector_follows_its_setting():
    assert collector.Collector(object(), enabled=lambda: False).ensure_started() is False


def test_collector_is_off_outside_hermes(monkeypatch):
    monkeypatch.setattr(config, "_hermes_config", lambda: None)
    assert config.collector_enabled() is False


def test_collector_setting_defaults_on_and_can_be_turned_off(monkeypatch):
    monkeypatch.setattr(config, "_hermes_config", lambda: {})
    assert config.collector_enabled() is True
    monkeypatch.setattr(config, "_hermes_config", lambda: {
        "plugins": {"entries": {config.PLUGIN_ID: {"settings": {"background_collector": False}}}}})
    assert config.collector_enabled() is False
    assert config.settings_from({"background_collector": False}, "").background_collector is False


def test_agent_scheduling_flag(monkeypatch):
    monkeypatch.setattr(config, "_hermes_config", lambda: {"cron": {"allow_agent_scheduling": True}})
    assert config.agent_scheduling_allowed() is True
    monkeypatch.setattr(config, "_hermes_config", lambda: {})
    assert config.agent_scheduling_allowed() is False


def test_catalog_uses_declared_pyyaml_only():
    from pathlib import Path
    assert "hermes_yaml" not in Path(catalog.__file__).read_text(encoding="utf-8")
