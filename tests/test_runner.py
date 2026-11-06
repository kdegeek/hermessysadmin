import pytest

from sysadmin.errors import ConnectionFailed, InvalidArguments, NotFound, PermissionDenied, RemoteScriptError
from sysadmin.runner import Runner, load_prelude, parse_output


class FakeTransport:
    def __init__(self, outputs):
        self.outputs = list(outputs)
        self.calls = []

    def invoke(self, script, params):
        self.calls.append((script, dict(params)))
        out = self.outputs.pop(0)
        if isinstance(out, BaseException):
            raise out
        return out

    def close(self):
        pass


@pytest.fixture
def scripts(tmp_path):
    (tmp_path / "hello.ps1").write_text("param($Name) Invoke-Op { @{ hi = $Name } }", encoding="utf-8")
    (tmp_path / "_prelude.ps1").write_text("PRELUDE", encoding="utf-8")
    return tmp_path


def test_parse_output_returns_data_from_last_json_line():
    assert parse_output(["noise", '{"ok":true,"data":{"a":1}}']) == {"a": 1}


def test_parse_output_maps_error_types():
    with pytest.raises(NotFound) as info:
        parse_output(['{"ok":false,"error":{"type":"NotFound","message":"no bob","target":"bob"}}'])
    assert info.value.details["target"] == "bob"
    with pytest.raises(PermissionDenied):
        parse_output(['{"ok":false,"error":{"type":"PermissionDenied","message":"denied"}}'])


def test_parse_output_unknown_error_type_is_remote_script_error():
    with pytest.raises(RemoteScriptError):
        parse_output(['{"ok":false,"error":{"type":"Weird","message":"x"}}'])


@pytest.mark.parametrize("out", [[], ["not json"], ["{bad"], ['{"data":1}']])
def test_parse_output_rejects_bad_output(out):
    with pytest.raises(RemoteScriptError):
        parse_output(out)


def test_run_loads_script_drops_none_params_and_parses(scripts):
    t = FakeTransport([['{"ok":true,"data":{"hi":"bob"}}']])
    r = Runner(t, scripts_dir=scripts)
    assert r.run("hello", {"Name": "bob", "Skip": None}) == {"hi": "bob"}
    assert t.calls == [("param($Name) Invoke-Op { @{ hi = $Name } }", {"Name": "bob"})]


def test_run_retries_once_on_connection_failure_when_requested(scripts):
    t = FakeTransport([ConnectionFailed("down"), ['{"ok":true,"data":1}']])
    assert Runner(t, scripts_dir=scripts).run("hello", {}, retry=True) == 1
    assert len(t.calls) == 2


def test_run_without_retry_raises_first_failure(scripts):
    t = FakeTransport([ConnectionFailed("down"), ['{"ok":true,"data":1}']])
    with pytest.raises(ConnectionFailed):
        Runner(t, scripts_dir=scripts).run("hello", {})
    assert len(t.calls) == 1


@pytest.mark.parametrize("name", ["../etc", "Hello", "missing", "a-b"])
def test_run_rejects_bad_or_missing_script_names(scripts, name):
    with pytest.raises(InvalidArguments):
        Runner(FakeTransport([]), scripts_dir=scripts).run(name, {})


def test_run_text_sends_text_verbatim(scripts):
    t = FakeTransport([['{"ok":true,"data":"x"}']])
    assert Runner(t, scripts_dir=scripts).run_text("Invoke-Op { 'x' }", {}) == "x"
    assert t.calls[0][0] == "Invoke-Op { 'x' }"


def test_load_prelude_reads_prelude(scripts):
    assert load_prelude(scripts) == "PRELUDE"


def test_real_prelude_defines_helpers():
    text = load_prelude()
    for name in (
        "function Global:Invoke-Op", "function Global:Get-HermesFanout", "function Global:Iso",
        "function Global:Get-CnName", "function Global:Get-ParentDn", "function Global:New-HermesPassword",
        "function Global:ConvertTo-HermesSecure", "function Global:Assert-Hermes",
        "function Global:ConvertTo-LdapValue", "function Global:Get-HermesGpo", "function Global:Get-XmlText",
        "$Global:HermesCred", "'*-AD*:Credential'", "'*-GP*:Server'",
    ):
        assert name in text
