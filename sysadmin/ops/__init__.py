"""Importing this package registers every operation in sysadmin.registry.OPS."""

from . import backup, catalog_ops, domain, fleet_ops, gpo, meta, modules, rdp, remote, users  # noqa: F401
from .. import catalog as _catalog

_catalog.load()
