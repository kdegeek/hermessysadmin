"""Runs vetted op scripts through a Transport and enforces the {ok, data|error} output contract."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Mapping

from .errors import ERROR_TYPES, ConnectionFailed, InvalidArguments, RemoteScriptError
from .transport import Transport

SCRIPTS_DIR = Path(__file__).resolve().parent / "scripts"
_SCRIPT_NAME = re.compile(r"^[a-z][a-z0-9_]*$")


def load_prelude(scripts_dir: Path = SCRIPTS_DIR) -> str:
    return (scripts_dir / "_prelude.ps1").read_text(encoding="utf-8")


def parse_output(out: list[Any]) -> Any:
    candidates = [o for o in out if isinstance(o, str) and o.strip().startswith("{")]
    if not candidates:
        raise RemoteScriptError(
            "The script returned no result.", output=" | ".join(str(o) for o in out)[:300]
        )
    text = candidates[-1]
    try:
        payload = json.loads(text)
    except ValueError as exc:
        raise RemoteScriptError("The script returned malformed JSON.", output=text[:300]) from exc
    if not isinstance(payload, dict) or "ok" not in payload:
        raise RemoteScriptError("The script result is missing 'ok'.", output=text[:300])
    if payload["ok"]:
        return payload.get("data")
    err = payload.get("error") or {}
    cls = ERROR_TYPES.get(str(err.get("type")), RemoteScriptError)
    raise cls(
        str(err.get("message") or "The remote script failed."),
        category=err.get("category"),
        target=err.get("target"),
    )


class Runner:
    def __init__(self, transport: Transport, scripts_dir: Path = SCRIPTS_DIR) -> None:
        self._transport = transport
        self._dir = scripts_dir
        self._cache: dict[str, str] = {}

    def close(self) -> None:
        self._transport.close()

    def load_script(self, name: str) -> str:
        if not _SCRIPT_NAME.match(name):
            raise InvalidArguments(f"Invalid script name {name!r}.")
        if name not in self._cache:
            path = self._dir / f"{name}.ps1"
            if not path.is_file():
                raise InvalidArguments(f"No script named {name!r}.")
            self._cache[name] = path.read_text(encoding="utf-8")
        return self._cache[name]

    def run(self, script: str, params: Mapping[str, Any], *, retry: bool = False) -> Any:
        return self._invoke(self.load_script(script), params, retry=retry)

    def run_text(self, text: str, params: Mapping[str, Any]) -> Any:
        return self._invoke(text, params, retry=False)

    def _invoke(self, text: str, params: Mapping[str, Any], *, retry: bool) -> Any:
        clean = {k: v for k, v in params.items() if v is not None}
        attempts = 2 if retry else 1
        out: list[Any] = []
        for attempt in range(attempts):
            try:
                out = self._transport.invoke(text, clean)
                break
            except ConnectionFailed:
                if attempt + 1 >= attempts:
                    raise
        return parse_output(out)
