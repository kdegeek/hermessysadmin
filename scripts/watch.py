"""Cron entry point for scheduled monitoring (launched by Hermes cron, see sysadmin/ops/monitoring.py).

Prints the new and resolved findings and nothing else: a clean run, an unconfigured plugin and any
error all print nothing and exit 0, so the cron job stays silent. Never prints secrets.

Hermes runs cron scripts with a sanitized environment. When the configured account needs a password,
list SYSADMIN_WINRM_PASSWORD under terminal.env_passthrough in the profile's config.yaml and Hermes
forwards it; this script never reads .env or any other credential store itself.
"""

from __future__ import annotations

import logging
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


def main(argv: list[str] | None = None) -> int:
    """--state prints the currently open alerts instead of the delta (agent mode: output change wakes the agent)."""
    state_mode = "--state" in (sys.argv[1:] if argv is None else argv)
    try:
        from sysadmin import monitor, runtime
        from sysadmin.config import load_settings

        settings = load_settings()
        if not settings.configured:
            return 0
        service = runtime.build_service(settings)
        try:
            text = monitor.run_once(service, settings)
            if state_mode:
                text = monitor.render_open(monitor.get_state().open())
        finally:
            try:
                service.runner.close()
            except Exception:
                pass
        if text:
            try:
                sys.stdout.reconfigure(encoding="utf-8")  # Windows cron pipes default to a legacy code page
            except Exception:
                pass
            print(text)
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    logging.disable(logging.CRITICAL)  # stdout is delivered verbatim; log noise would become an alert
    sys.exit(main())
