---
name: backup-recovery-guide
description: 'Runbook for Active Directory recovery with Windows Server Backup. It covers checking backups, taking a fresh system-state backup, and guiding non-authoritative and authoritative restores (DSRM, wbadmin, ntdsutil), plus single-object recovery via the AD Recycle Bin. Use when a DC fails, objects are deleted, or someone asks how to restore AD.'
---

# AD backup and recovery

The plugin does not perform restores. Restores need console or DSRM access to the DC. Use the tools to assess the situation and prepare, then walk the user through the steps.

## 1. Assess
- Call `backup_status` and `backup_versions` for the affected DC. Confirm that a system-state version exists and is newer than the tombstone lifetime (180 days by default).
- For deleted objects, call `ad_recycle_bin_list` first. If the object is there, call `ad_recycle_bin_restore`. This is the simplest recovery and needs no DC restore.

## 2. Protect what is left
- If any healthy DC has a stale backup, offer `backup_start` with `kind: "system_state"` and watch progress with `backup_jobs`.

## 3. Choose the restore type
- **Non-authoritative** (one DC is corrupt or failed; other DCs are healthy): the restored DC catches up through replication. Often it is simpler to demote and rebuild the DC.
- **Authoritative** (deleted objects must win over replication and the Recycle Bin was not enabled): restore non-authoritatively first, then mark the objects authoritative.

## 4. Steps to give the user (run at the DC console)
1. Boot into Directory Services Restore Mode: `bcdedit /set safeboot dsrepair`, then restart. Sign in with the DSRM administrator password (it is not a domain password; reset it beforehand with `ntdsutil "set dsrm password"` if nobody knows it).
2. `wbadmin get versions`, then `wbadmin start systemstaterecovery -version:<id>`. For an authoritative restore, answer **No** when wbadmin offers to restart, or the chance to mark objects authoritative is lost.
3. For authoritative restores only, still in DSRM and before restarting:
   - `ntdsutil "activate instance ntds" "authoritative restore" "restore subtree <DN>" q q`
   - If SYSVOL must also win, add `-authsysvol` to the `wbadmin start systemstaterecovery` command in step 2.
   - On older forests without linked-value replication, import the generated LDIF files to restore back-links (group memberships).
4. `bcdedit /deletevalue safeboot`, then restart.
5. Verify the result with `ad_dc_health` and `ad_search` for the restored objects.

Never suggest restoring a DC from a VM snapshot (it causes USN rollback). Never run these steps through `ad_powershell`.
