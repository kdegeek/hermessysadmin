---
name: offboard-user
description: 'Safely offboard a departing user in Active Directory: disable, reset to a random password, remove group memberships (recorded for restore), move to a Disabled OU, log off RDP sessions and stamp the description. Use when someone leaves or an account must be shut off.'
---

# Offboard a user

Ask for the user, the ticket or reference, and the Disabled OU's DN (look it up with `ad_search` and `kind: "ou"` if needed). Then confirm the plan in one message before you start.

1. **Snapshot.** Call `ad_user_get`. Keep the full group list in your reply; it is the restore record, and every removal is also in the audit log (`sysadmin_audit_log`).
2. **Disable.** Call `ad_user_disable` with `note` set to `Offboarded <YYYY-MM-DD> <ticket>`.
3. **Random password.** Call `ad_user_reset_password` with no `password` and `must_change: false`. Do not show the generated password. Say only that it was rotated.
4. **Sessions.** Call `rdp_sessions` with `user`. For each session found, call `rdp_session_logoff` with that host and `session_id`.
5. **Groups.** For each group except Domain Users, call `ad_group_remove_member`. Privileged groups are high-risk and need their own approval.
6. **Move.** Call `ad_user_move` with `target_ou` set to the Disabled OU.
7. **Report.** List what changed and the groups removed (the restore list). Recommend deleting the account only after the retention period. `ad_user_delete` is high-risk; do not call it unless explicitly asked.
