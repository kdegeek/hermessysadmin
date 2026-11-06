"""Importing this package registers every operation in sysadmin.registry.OPS."""

from . import backup, domain, gpo, meta, rdp, users  # noqa: F401
from .. import catalog as _catalog

_catalog.load()
