---
name: remote-assist
description: 'Get remote access to one desktop: check what is needed, see who is logged on, then offer Remote Assistance or consent-based shadowing when a user is present, or an RDP file when nobody is. Use for "connect to X", "help the user on X" or "I need to see their screen".'
---

# Remote assist

1. **Check first.** Call `remote_access_check` for the computer. For each failing check, propose the `remote.*` catalog entry it names (for example `remote.enable_rdp`, `remote.open_rdp_firewall`, `remote.set_nla`, `remote.add_rdp_user`, `remote.enable_remote_assistance`, `remote.set_shadow_policy`) and run it with `catalog_run` only after the user approves.
2. **Who is there.** Call `remote_sessions` with `computers: [that computer]`.
3. **A user is present.**
   - Offer Remote Assistance with `remote_assist_command`: the user is asked to accept, so it is consent-based.
   - Or shadow their session with `remote_shadow_command` using the session ID from step 2, keeping `consent: true` so the user is prompted.
   - Hand the admin the command (or the saved `.cmd` file) to run on their own machine.
4. **Nobody is logged on.** Use RDP: call `rdp_connect_file` and give the admin the `.rdp` file.
5. **No-consent shadowing is high-risk.** Never use `consent: false` unless the admin explicitly asks for it, and say plainly that it is high-risk and needs approval.

If the machine is offline, say so; none of these work until it is back.
