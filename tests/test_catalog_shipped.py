import pytest
from sysadmin import catalog

FILES = sorted(catalog.CATALOG_DIR.glob("*/*.ps1"))


@pytest.mark.parametrize("path", FILES, ids=lambda p: f"{p.parent.name}/{p.name}")
def test_every_shipped_entry_is_valid(path):
    catalog.parse_entry(path)
