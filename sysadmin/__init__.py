"""Core library for the hermes-sysadmin plugin.

Nothing in this package imports Hermes at module load, so it can be unit-tested
without a Hermes install and imported by the dashboard backend by path.
"""

PLUGIN_ID = "hermes-sysadmin"
__version__ = "0.1.0"
