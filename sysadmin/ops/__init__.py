"""Importing this package registers every operation in sysadmin.registry.OPS."""

from . import backup, catalog_ops, domain, gpo, meta, modules, rdp, users  # noqa: F401
from .. import catalog as _catalog

_catalog.load()
