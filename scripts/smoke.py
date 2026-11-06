"""Manual smoke test against a real domain, without Hermes.

    export SYSADMIN_HOST=dc01.corp.example.local SYSADMIN_USER='CORP\\svc-hermes'
    read -s SYSADMIN_WINRM_PASSWORD && export SYSADMIN_WINRM_PASSWORD
    .venv/bin/python scripts/smoke.py ad_connection_test
    .venv/bin/python scripts/smoke.py ad_search '{"query": "bob"}'
    .venv/bin/python scripts/smoke.py ad_user_unlock '{"identity": "zz-hermes-test-1"}' --approve
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from sysadmin import ops  # noqa: E402,F401
from sysadmin.audit import open_audit  # noqa: E402
from sysadmin.config import settings_from  # noqa: E402
from sysadmin.runner import Runner, load_prelude  # noqa: E402
from sysadmin.service import Service  # noqa: E402
from sysadmin.transport import PsrpTransport  # noqa: E402


def env_settings():
    raw = {
        "host": os.environ["SYSADMIN_HOST"],
        "username": os.environ["SYSADMIN_USER"],
        "use_https": os.environ.get("SYSADMIN_HTTPS", "true"),
        "verify_tls": os.environ.get("SYSADMIN_VERIFY_TLS", "true"),
        "port": os.environ.get("SYSADMIN_PORT"),
        "mode": "strict",
    }
    return settings_from(raw, os.environ["SYSADMIN_WINRM_PASSWORD"])


def main(argv: list[str]) -> int:
    flags = [a for a in argv if a.startswith("--")]
    positional = [a for a in argv if not a.startswith("--")]
    if not positional:
        print(__doc__)
        return 2
    name = positional[0]
    args = json.loads(positional[1]) if len(positional) > 1 else {}
    settings = env_settings()
    service = Service(settings, Runner(PsrpTransport(settings, load_prelude())), open_audit())
    if "--preview" in flags:
        result = service.preview(name, args)
    else:
        result = service.call(name, args, actor="command", approved="--approve" in flags)
    print(json.dumps(result, indent=2, default=str))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
