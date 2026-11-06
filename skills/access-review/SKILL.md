---
name: access-review
description: 'Review who has privileged and remote access in Active Directory: privileged group members, Remote Desktop Users per server, RDP posture, and accounts with non-expiring passwords; produce a review table with recommended removals. Use for audits, quarterly access reviews or "who are our admins".'
---

# Access review

1. **Privileged groups.** For each of Domain Admins, Enterprise Admins, Schema Admins, Administrators, Account Operators, Server Operators, Backup Operators and Group Policy Creator Owners, call `ad_group_get`. Flag nested groups, disabled members and members whose last logon is more than 90 days ago (use `ad_user_get` for details).
2. **Remote Desktop.** Call `rdp_host_status` for all servers. List the Remote Desktop Users members for each host and every warning (NLA off, firewall rules disabled).
3. **Password policy exceptions.** Call `ad_user_list` with `password: "never_expires"`. Separate service accounts from people.
4. **Report.** Build one table: principal · access · where · last logon · recommendation (keep / remove / investigate).
5. **Remediate only on request.**
   - Removals use `ad_group_remove_member` (privileged groups are high-risk) or `rdp_users_remove`.
   - Turning NLA on uses `rdp_set_nla` with `required: true`.

   Every change needs approval and is logged; `sysadmin_audit_log` shows them afterwards.
