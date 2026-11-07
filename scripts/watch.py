"""Cron entry point for scheduled monitoring (launched by Hermes cron, see sysadmin/ops/monitoring.py).

Prints the new and resolved findings and nothing else: a clean run, an unconfigured plugin and any
error all print nothing and exit 0, so the cron job stays silent. Never prints secrets.
"""

from __future__ import annotations

import logging
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


def _load_hermes_env() -> None:
    """Under cron nothing has loaded Hermes's .env yet; use Hermes's own loader (as verify_live.py does)."""
    try:
        from hermes_cli.env_loader import load_hermes_dotenv
    except ImportError:
        return
    try:
        load_hermes_dotenv()
    except Exception:
        pass


def main() -> int:
    logging.disable(logging.CRITICAL)  # stdout is delivered verbatim; log noise would become an alert
    try:
        _load_hermes_env()
        from sysadmin import monitor, runtime
        from sysadmin.config import load_settings

        settings = load_settings()
        if not settings.configured:
            return 0
        service = runtime.build_service(settings)
        try:
            text = monitor.run_once(service, settings)
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
    sys.exit(main())
