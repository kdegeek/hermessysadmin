---
name: gpo-change
description: 'Make a Group Policy change safely: back up, apply (link/unlink/enforce/status/security filter), refresh a test host, verify with RSoP, and roll back on failure. Use for any request that changes where or how a GPO applies.'
---

# Change Group Policy safely

1. **Understand the GPO.** Call `gpo_get` for its links and security filtering, and `gpo_report` (`format: "summary"`) for what it configures. Restate the intended effect in one sentence and confirm it.
2. **Back up.** Call `gpo_backup` with a comment that describes the change. Keep the returned backup ID.
3. **Apply to a pilot first.** A link or filter change reaches every computer in scope at its next background refresh (about 90 minutes), so a manual refresh of one host is not a canary. For a new link, link first to a small pilot OU, or first restrict the security filter to a pilot group with `gpo_set_security_filter`, and widen only after step 5 passes. Read the approval preview before approving. Use the narrowest tool:
   - `gpo_link` or `gpo_unlink` to change where the GPO applies. Linking at the domain root, the Domain Controllers OU or a site is high-risk.
   - `gpo_set_link` to enforce, unenforce, enable or disable a link.
   - `gpo_set_status` to switch user or computer settings on or off.
   - `gpo_set_security_filter` to change who the GPO applies to.

   Create new GPOs with `gpo_create`. Editing settings is out of scope; tell the user to use GPMC for that.
4. **Refresh a test host.** Ask for one computer in scope, then call `gpo_update_hosts` with `computers: [that host]`.
5. **Verify.** Call `gpo_rsop` on that computer and check that the GPO is listed as applied (or no longer applied). If the result is wrong, explain why from the RSoP output: filtered, access denied, or not linked.
6. **Roll back on failure.** If verification fails and the user agrees, undo the change with the opposite tool: `gpo_unlink`/`gpo_link` for links, `gpo_set_link` for enforce or enable changes, `gpo_set_status` or `gpo_set_security_filter` to revert those. For settings changes, confirm the backup ID with `gpo_backups`, then call `gpo_restore` and read its preview before approving.
7. **Roll out.** When the pilot result is right, widen the link or filter to the intended scope, then offer `gpo_update_hosts` for the whole OU (`ou`). Finish with what changed and the backup ID.
