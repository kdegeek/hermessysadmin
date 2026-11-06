---
name: domain-health-check
description: 'Run a full Active Directory health check (domain controllers, replication, FSMO, time, SYSVOL, backup staleness, GPO health, privileged membership, account hygiene) and produce a prioritised report. Use for "is AD healthy", weekly checks, or before maintenance.'
---

# Domain health check

Run these reads; all of them are read-only and need no approval:

1. `ad_domain_overview`: counts, FSMO holders, functional levels, Recycle Bin status.
2. `ad_dc_health`: per-DC services, SYSVOL/NETLOGON shares, time skew and replication failures.
3. `backup_status`: system-state backup age per server against the configured stale threshold. Pay most attention to DCs.
4. `gpo_health`: unlinked, empty, disabled or version-mismatched GPOs.
5. `ad_user_list` with `privileged: true`: who holds admin rights.
6. `ad_user_list` with `password: "never_expires"`, then with `stale_days: 90`: hygiene.

Write the report as:
- **Critical:** a DC down or failing replication, a DC without a recent system-state backup, time skew over 5 minutes.
- **Warnings:** stale backups on other servers, GPO version mismatches, a growing privileged group, many stale or never-expiring accounts.
- **Info:** counts and FSMO placement.

Give each item the evidence (the numbers) and one concrete next action. Offer the matching skill (for example `gpo-change` or `backup-recovery-guide`) where it helps. Do not change anything during a health check.
