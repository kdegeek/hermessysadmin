---
name: fleet-health-check
description: 'Check the health of every desktop in the fleet (offline machines, low disk, patch age, pending reboots, Defender, BitLocker, RDP without NLA), rank the problems and propose catalog fixes. Use for "how is the fleet", weekly desktop checks, or "which PCs need attention".'
---

# Fleet health check

1. **Inventory.** Call `fleet_inventory` (read-only; use `refresh: true` if the user wants a fresh probe). Report the summary counts first.
2. **Rank the problems,** worst first:
   1. Offline for more than 7 days.
   2. Low disk on C: (below the configured threshold).
   3. Patch age (no update installed for too long).
   4. Pending reboots.
   5. Defender off or out of date.
   6. BitLocker off.
   7. RDP enabled without NLA.
3. **Find the fix.** For the top issues call `catalog_search` for a matching entry and read it with `catalog_get`. Useful read entries to confirm before changing anything: `security.defender_status`, `security.bitlocker_status`, `security.rdp_nla`, `endpoint.pending_reboot`, `endpoint.disk_usage`, `patch.pending_updates`.
4. **Propose, do not apply.** Offer the fix with `catalog_run` (for example `remote.set_nla`, `maint.clear_temp`, `patch.trigger_scan`, `remote.restart_computer`) and name the computers. Writes need approval. Never batch more than 10 machines without saying that it will be a high-risk change; with more than 10 machines, an OU, or no explicit computer list the approval is high-risk.
5. **Finish with a short table:** problem, count, example computers, proposed catalog id.

Do not change anything during the check itself. Offer `endpoint-triage` for a single machine that needs a closer look.
