# Changelog

## 0.1.0 — 2026-11-11

First release (Nous Research Hermes Agent Plugin Hackathon).

- 56 typed tools across six toolsets: domain, users, Group Policy, RDP, Windows Server Backup, meta. One of them, the raw PowerShell escape hatch (`ad_powershell`), is opt-in and off by default.
- Tiered safety policy (read / write / high-risk / protected), strict, permissive and read-only modes, privileged-group and domain-controller escalation, protected objects (matched by name, DN and SID) and privileged groups (matched by name, SID and GUID).
- Approval through Hermes's `pre_tool_call` hook, with previews for high-risk changes and no truncation of the arguments or script a human approves; local SQLite audit log with password redaction.
- Seven workflow skills and the `/ad` slash command.
- Hermes Desktop dashboard: Overview, Users, Group Policy, Remote Access, Backups, Audit. Dashboard writes require confirmation, and high-risk ones a typed object name.
- Opt-in live test suite (`SYSADMIN_LIVE=1`) and GitHub Actions CI.
