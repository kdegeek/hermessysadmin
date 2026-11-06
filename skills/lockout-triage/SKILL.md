---
name: lockout-triage
description: 'Find out why an Active Directory account keeps locking out, identify the source computer, explain the likely cause (stale credentials in a service, mapped drive, phone, RDP session), unlock it and give a fix. Use for "X is locked out" or repeated lockouts.'
---

# Lockout triage

1. **State.** Call `ad_user_get`. Note whether the account is locked, its bad-password count and lockout time.
2. **Source.** Call `ad_lockout_source` (`hours: 24`; widen to 72 for recurring cases). Report `likely_source` and the 4740 events from the PDC emulator and bad-password counts per DC.
3. **Inspect the source.**
   - If the source is a server, call `rdp_sessions` with `hosts` set to that server and `user` set to the account. A disconnected session that was left running with an old password is the classic cause.
   - If the source is a workstation or a phone or Wi-Fi name (often a blank or odd caller name), say that it is probably cached credentials on a device.
4. **Unlock.** Call `ad_user_unlock`. If the user also forgot the password, call `ad_user_reset_password` instead; it unlocks too.
5. **Fix the cause.** Give the specific next step:
   - Log off the stale session with `rdp_session_logoff`.
   - Update the saved credentials on the device.
   - Update a service or scheduled task's stored password.
   - Remove a mapped drive that uses old credentials.

   If lockouts continue after the fix, say that `ad_lockout_source` should be re-run.
