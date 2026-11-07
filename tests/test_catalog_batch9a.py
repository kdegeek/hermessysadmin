import re

from sysadmin import catalog
import sysadmin.ops  # noqa: F401  (registers the shipped catalog)

BATCH_9A = {"ad.stale_computers", "ad.stale_users", "ad.never_expiring_passwords", "ad.password_not_required",
            "ad.reversible_encryption", "ad.spn_accounts", "ad.asrep_roastable", "ad.unconstrained_delegation",
            "ad.empty_groups", "ad.admincount_orphans", "ad.krbtgt_age", "ad.laps_coverage",
            "ad.replication_summary", "ad.dfs_health", "ad.last_backup", "ad.duplicate_spn", "ad.trusts",
            "ad.password_policies", "ad.kerberos_accounts", "ad.fsmo_available"}
BANNED = ('ms-Mcs-AdmPwd"', 'msLAPS-Password"', "msLAPS-EncryptedPassword", "unicodePwd",
          "supplementalCredentials", "PingCastle")


def ids():
    return {o.meta["id"]: o for o in catalog.entries()}


def source(entry_id):
    area, name = entry_id.split(".")
    return (catalog.CATALOG_DIR / area / f"{name}.ps1").read_text()


def test_batch_9a_present_read_only_dc():
    got = ids()
    assert len(BATCH_9A) == 20 and BATCH_9A <= set(got)
    for i in BATCH_9A:
        assert got[i].tier == "R" and got[i].meta["target"] == "dc", i
        assert got[i].meta["category"] == "AD hygiene", i


def test_every_gallery_entry_uses_the_module_loader():
    for i in BATCH_9A:
        if str(ids()[i].meta["module"]).startswith("gallery:"):
            assert "Use-HermesModule" in source(i), i


def test_no_secret_attributes_or_pingcastle():
    for i in BATCH_9A:
        text = source(i)
        assert not [b for b in BANNED if b in text], i


def test_laps_coverage_reads_only_expiration_attributes():
    text = source("ad.laps_coverage")
    assert "msLAPS-PasswordExpirationTime" in text and "ms-Mcs-AdmPwdExpirationTime" in text
    for name in re.findall(r"ms(?:LAPS|-Mcs)-[A-Za-z]+", text):
        assert name.endswith("ExpirationTime"), name


def test_rows_are_capped_and_flag_truncation():
    for i in BATCH_9A - {"ad.fsmo_available", "ad.krbtgt_age"}:
        text = source(i)
        assert "Select-Object -First 500" in text and "truncated" in text, i


def test_header_columns_are_emitted_by_the_rows():
    for i in BATCH_9A:
        text = source(i)
        body = text.split("#>", 1)[1]
        for col in ids()[i].meta["columns"]:
            if col == "host":  # added by the fan-out
                continue
            assert re.search(rf"\b{col}\s*=", body), (i, col)


def test_admincount_resolves_protected_groups_by_sid_not_name():
    text = source("ad.admincount_orphans")
    assert "Get-ADGroupMember" in text and "-Recursive" in text
    for rid in ("512", "516", "518", "519", "521", "526", "527"):
        assert rid in text
    for sid in ("S-1-5-32-544", "S-1-5-32-548", "S-1-5-32-549", "S-1-5-32-550", "S-1-5-32-551", "S-1-5-32-552"):
        assert sid in text
    assert "Domain Admins" not in text.split("#>", 1)[1]


def test_replication_summary_avoids_cross_dc_rpc():
    text = source("ad.replication_summary")
    assert "-Target $me" in text and "Invoke-HermesCatalogFanout" in text
    assert "/showrepl $env:COMPUTERNAME" in text and "/showrepl *" not in text
