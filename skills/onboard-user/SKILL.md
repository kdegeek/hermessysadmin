---
name: onboard-user
description: 'Create a new Active Directory user from a template or role (OU, groups), set an initial password, optionally grant RDP access, and hand back a summary. Use when asked to onboard, add, or set up a new employee or account.'
---

# Onboard a user

1. **Gather inputs.** You need first and last name and a logon name (sAMAccountName). Ask for a template user ("same as Jane") or an OU, plus title and department. Do not invent a logon name: propose one that follows the domain's pattern (`ad_user_list` with `query` set to a colleague) and confirm it.
2. **Check for collisions.** Call `ad_search` with the proposed logon name. If it exists, stop and ask.
3. **Inspect the template.** Call `ad_user_get` on the template to show its OU and groups. Privileged groups are never copied. Say so if the template has any.
4. **Create.** Call `ad_user_create` with `template` (or `ou`), the names, title, department and `must_change: true`. Omit `password` so one is generated. The user approves the call.
5. **Extra groups.** For each extra group the user asked for, call `ad_group_add_member`. A privileged group becomes a high-risk approval; explain why before you call it.
6. **RDP (optional).** If they need remote desktop access to specific servers, call `rdp_users_add` with each host.
7. **Summarise.** Give the logon name, UPN, OU, groups and RDP hosts. Show the generated password **once**, and tell the user to pass it on through a secure channel. Never repeat the password later in the conversation.
