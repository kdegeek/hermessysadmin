---
name: endpoint-triage
description: 'Diagnose one desktop that a user says is slow or broken: device detail, top processes, recent errors, pending reboot, disk space and stopped services, then suggest fixes. Use for "my PC is slow", "this computer keeps crashing" or "check workstation X".'
---

# Endpoint triage

1. **Device.** Call `fleet_device` with the computer name. Note whether it is online, its uptime, disk, patch age and who is logged on. If it is offline, say so and stop; offer `remote_access_check` once it is back.
2. **Gather evidence** with `catalog_run`, each with `computers: [that computer]` (all read-only):
   - `endpoint.top_processes`
   - `endpoint.recent_errors`
   - `endpoint.pending_reboot`
   - `endpoint.disk_usage`
   - `endpoint.stopped_auto_services`
3. **Diagnose.** Name the most likely cause with the numbers behind it: a runaway process, a full C: drive, a long uptime with a pending reboot, a crashing or stopped service, repeated errors from one provider.
4. **Suggest fixes** as catalog ids, each run with `catalog_run` and each needing approval:
   - `maint.clear_temp` for a full drive (the plan shows sizes first).
   - `maint.restart_service` for a stopped or stuck service.
   - `remote.restart_computer` for a pending reboot or a hung machine (high-risk; confirm the user is not mid-work, see `remote_sessions`).

Always target the single computer. Do not run any fix until the user agrees, and re-run the failing read afterwards to confirm it helped.
