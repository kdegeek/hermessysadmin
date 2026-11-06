# Hermes Sysadmin · Active Directory

Manage an on-prem Active Directory domain from Hermes Agent over WinRM. It covers users, groups and lockouts, Group Policy, RDP sessions and access, and Windows Server Backup. Every change goes through typed tools with tiered approvals, protected objects and a local audit log. The plugin also ships workflow skills, `/ad` commands and a Hermes Desktop dashboard.

![Overview](docs/screenshots/overview.png)

## What you get

56 typed tools in six toolsets (domain 5, users and groups 17, Group Policy 16, RDP 10, backup 6, meta 2). One of them, the raw PowerShell escape hatch `ad_powershell`, is only registered when you turn it on, so a default install exposes 55.

| Surface | Agent tools | Dashboard |
|---|---|---|
| Domain | DC list and health (services, SYSVOL, time skew, replication), domain overview, search, connection test | Overview KPIs and DC table |
| Users and groups | get/list/create/update, reset password (one-time reveal), unlock, enable/disable, move, delete, group membership, lockout source, Recycle Bin | Users tab, drawer, dialogs |
| Group Policy | list with health, settings report, RSoP, link/unlink/enforce, status, security filtering, gpupdate, backup/restore/delete | Group Policy tab |
| Remote Access | sessions across servers, log off/disconnect/message, RDP and NLA toggles, Remote Desktop Users, `.rdp` Connect | Remote Access tab |
| Backup | Windows Server Backup status with staleness, versions, jobs, start/cancel, policy | Backups tab |
| Meta | audit log query; optional raw PowerShell (off by default) | Audit tab |

Skills: `onboard-user`, `offboard-user`, `lockout-triage`, `gpo-change`, `domain-health-check`, `access-review`, `backup-recovery-guide`.

Commands: `/ad status`, `/ad user <name>`, `/ad unlock <name>`, `/ad sessions [host]`, `/ad backups`.

## Requirements

- Hermes Agent >= 0.22.2. Hermes Desktop is needed for the dashboard.
- **A domain controller as the WinRM jump host.** Group Policy cmdlets cannot take explicit credentials, so Hermes talks to one DC. That DC runs AD and GPO work locally and reaches member servers (RDP, backup, gpupdate, RSoP) with an explicit credential.
- WinRM on that DC: HTTPS on 5986 (recommended) or HTTP on 5985 with NTLM/Kerberos message encryption. To enable HTTPS on the DC (elevated PowerShell):
  ```powershell
  $cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME, ([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName) -CertStoreLocation Cert:\LocalMachine\My
  New-Item -Path WSMan:\LocalHost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $cert.Thumbprint -Force
  New-NetFirewallRule -DisplayName 'WinRM HTTPS' -Direction Inbound -LocalPort 5986 -Protocol TCP -Action Allow
  ```
  With a self-signed certificate, turn off **Verify TLS certificate** (lab only).
- WinRM enabled on member servers you want in the Remote Access and Backups tabs (`Enable-PSRemoting`). The Windows Server Backup feature is needed on servers you back up.
- An account with delegated rights. Domain Admin works for a lab, but delegate in production.

## Install

```bash
hermes plugins install hermes-sysadmin --enable      # from the catalog
# or, from source:
hermes plugins install <owner>/hermessysadmin --enable
```

Open **Settings → Plugins → Sysadmin · Active Directory** and set the jump host, username and password. The password is stored in Hermes secrets. Then click **Test connection** on the dashboard's first-run card.

Settings: `host`, `port`, `use_https`, `auth` (ntlm/kerberos), `username`, `password` (secret `SYSADMIN_WINRM_PASSWORD`), `verify_tls`, `server_search_base`, `backup_stale_days`, `mode`, `protected_objects`, `privileged_groups`, `enable_powershell_escape`.

## Safety model

| Tier | Examples | strict (default) | permissive | read-only |
|---|---|---|---|---|
| Read | list, get, report, status | runs | runs | runs |
| Write | unlock, reset password, link GPO, log off, start backup | approval | runs | blocked |
| High-risk | delete user, GPO delete/restore, backup policy, raw PowerShell; plus escalated writes: privileged-group membership, GPO links at the domain root / DC OU / sites, RDP or Remote Desktop Users on a DC, disabling NLA | approval (with preview where one exists) | approval (with preview where one exists) | blocked |
| Protected | krbtgt, Administrator, your denylist | blocked | blocked | blocked |

- The agent asks through Hermes's own approval prompt. High-risk approvals use a one-time key, so an "always allow" never carries over to the next high-risk call.
- Protected accounts are matched by name, distinguished name and SID (including the domain's built-in Administrator and krbtgt SIDs). Privileged groups are matched by name, SID and GUID, so renaming or addressing a group by another identifier does not bypass escalation. An identity the policy cannot interpret is blocked rather than allowed.
- The approval prompt never truncates what you are approving. Previews are length-limited with an explicit truncation marker, and for high-risk calls without a preview, including the `ad_powershell` escape hatch, every argument and the full script are shown.
- The dashboard requires a confirm dialog for every write, and high-risk changes also make you type the object's name. The API refuses writes that lack that confirmation.
- Every write attempt is logged, whether allowed, approved, denied, blocked or failed: who, what, target, tier and result. Passwords are redacted.
- No input is ever interpolated into PowerShell. Each tool runs one vetted script with bound parameters. The single exception is the optional `ad_powershell` tool, which is off by default, high-risk on every call, and shows the full script in the approval.

## Disclosures

- **Network:** WinRM (5985/5986) to the configured jump host only. The jump host then makes WinRM connections to member servers you target (RDP, backup and gpupdate features). No other network calls, and no telemetry.
- **Shell:** no local shell. PowerShell runs remotely on the jump host.
- **Credentials:** the WinRM password is read only through Hermes secrets (`get_secret`). It is sent to the jump host for authentication and, for fan-out, used there as an explicit credential. It is never logged.
- **Files:** a SQLite audit log in the plugin's Hermes data folder. GPO backups are written on the DC under `%ProgramData%\HermesSysadmin\GpoBackups`. The dashboard's Connect button may save a `.rdp` file to a folder you choose.
- **Background work:** none in Hermes. Backups are server-side Windows Server Backup jobs, and the dashboard polls while open.

## Development

```bash
uv venv --python 3.11 .venv && uv pip install -r requirements-dev.txt "pypsrp>=0.8.1,<0.9"
.venv/bin/pytest                      # unit, contract, parse (needs pwsh) and desktop lint
ln -s "$PWD" ~/.hermes/plugins/hermes-sysadmin && hermes plugins enable hermes-sysadmin
SYSADMIN_LIVE=1 .venv/bin/pytest tests/live -v     # against a lab domain (see tests/live)
```

The live suite is skipped unless `SYSADMIN_LIVE=1`. It reads `SYSADMIN_HOST`, `SYSADMIN_USER`, `SYSADMIN_WINRM_PASSWORD` (and optionally `SYSADMIN_PORT`, `SYSADMIN_HTTPS`, `SYSADMIN_VERIFY_TLS`). Add `SYSADMIN_LIVE_WRITE=1` with `SYSADMIN_TEST_OU` for write tests, which only touch `zz-hermes-test-*` objects and clean up after themselves, and `SYSADMIN_TEST_SERVER` for host-specific reads.

## Screenshots

| Users | Group Policy | Remote Access |
|---|---|---|
| ![](docs/screenshots/users.png) | ![](docs/screenshots/gpo.png) | ![](docs/screenshots/rdp.png) |
| **Backups** | **Audit** | |
| ![](docs/screenshots/backups.png) | ![](docs/screenshots/audit.png) | |

## License

MIT
