# Hermes Sysadmin v0.2 (RMM) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the hermes-sysadmin plugin into an agent-first Windows/AD RMM. It gains a fleet inventory, a vetted metadata-driven PowerShell catalog (about 70 entries, some wrapping pinned Gallery modules), an Overview with charts, remote access to desktops, and scheduled monitoring with alerts.

**Architecture:** Every new capability is an `Op` executed by the existing `Service.call()`, so tiers, protected objects, approvals, audit and cache invalidation apply unchanged. Catalog entries are `.ps1` files with a YAML header. `sysadmin/catalog.py` loads them as `cat.<id>` Ops, and the agent reaches them through three tools: `catalog_search`, `catalog_get` and `catalog_run`. Fleet snapshots and alert state live in a plugin SQLite DB. The desktop bundle is built from `desktop/src/*.js` into a single `desktop/plugin.js`.

**Tech Stack:** Python 3.11+ (pypsrp, PyYAML from the Hermes runtime, sqlite3, pytest), PowerShell 5.1 on the DC (ActiveDirectory, GroupPolicy and in-box modules, plus pinned PSGallery modules), Hermes Desktop plugin SDK (ESM, `jsx()`, `var(--ui-*)`), node for `--check` and `node --test`.

**Spec:** `docs/superpowers/specs/2026-11-06-hermes-sysadmin-rmm-design.md`. When this plan and the spec disagree, the spec governs. Exception: this plan narrows the catalog `preview` values to `none | plan` (§3.2 "whatif" is implemented as a plan preview inside the script). Task 2 updates the spec line.

## Global Constraints

- Target **Windows PowerShell 5.1** on the DC. PS7-only operators (`??`, `?.`, `&&`, `||`) are banned everywhere, including catalog entries.
- Every `.ps1` (core `sysadmin/scripts/` and `catalog/**`) starts with `param(...)`, followed by a single `Invoke-Op { ... }` block and nothing after it. Forbidden: `Invoke-Expression`, `iex`, `Add-Type`, `DownloadString`, `Start-Process`, `[scriptblock]::Create`, `NewScriptBlock`, `InvokeScript`, `Invoke-Command`. Fan-out goes **only** through the prelude helpers (`Get-HermesFanout`, `Invoke-HermesOne`, `Invoke-HermesCatalogFanout`). `Invoke-WebRequest` is allowed **only** in `sysadmin/scripts/catalog_module_install.ps1`.
- Write scripts that support preview return `@{ summary = <string>; changes = @(<strings>); current = <hashtable> }` when `-Preview` is set, **before** changing anything.
- Tiers are `R`, `W` and `H`. For catalog and remote writes, a W escalates to H when any of these hold: more than 10 targets, `ou` given, no explicit computers (fallback to all), or any target is a DC. An unknown DC list fails closed (escalate).
- Only `destructive: true` entries make the dashboard ask the user to type the target name.
- Gallery modules run **on the DC only**, from `C:\ProgramData\HermesSysadmin\Modules`. Never `Install-Module`, never `Update-Module`, and the machine `PSModulePath` is never changed. The lock pins `name`, `version` and `package_hash` (PSGallery SHA-512 base64).
- Never include DSInternals, PSWinDocumentation.AD, PowerSploit, Mimikatz wrappers, `Get-LapsADPassword`, `Get-AdmPwdPassword`, `Get-RequestArchivedKey`, or ADEssentials' PingCastle functions. No entry ever outputs a password, recovery key or `cpassword` value.
- No live write against the user's domain without the user approving that specific action. Live verification is **read-only** (`scripts/verify_live.py` forces `mode="read-only"`; writes are exercised with `Service.preview()` only).
- Secrets come only from `agent.secret_scope.get_secret("SYSADMIN_WINRM_PASSWORD", None)` (already in `config.py`). Never read `.env`, `auth.json` or credential stores directly.
- Desktop: SDK imports only (`react`, `react/jsx-runtime`, `@hermes/plugin-sdk`). Colours come only from `var(--ui-*)`, and class names use the `hs-` prefix. Edit `desktop/src/*.js`, never `desktop/plugin.js` by hand. Run `python3 scripts/build_desktop.py` after every desktop edit.
- Python handlers never raise to Hermes. They return `{"ok": false, "error": {...}}` through `error_result`.
- Tests: `.venv/bin/python -m pytest -q` must pass, and so must `node --check desktop/plugin.js` and `node --test desktop/tests/`. `pwsh` is installed at `/opt/homebrew/bin/pwsh` for the parse check.
- Commit messages end with the `Co-Authored-By:` trailer from your own system reminder.

## Phases and tasks

| File | Tasks |
|---|---|
| `01-foundations.md` | 1 Desktop source split + build · 2 Catalog core (loader, runner, prelude helpers, lint) · 3 Catalog agent surface (search/get/run, hooks, /ad, API) · 4 Pinned Gallery modules |
| `02-fleet-remote.md` | 5 Fleet inventory + snapshot store · 6 Remote access to desktops |
| `03-catalog-content.md` | 7 Endpoint health, sessions, maintenance, remote fixes · 8 Security posture + patching · 9 AD hygiene, Group Policy, DNS/DHCP · 10 Network, printers, certificates, event logs, file permissions |
| `04-monitoring.md` | 11 Monitor rules, watch script, cron setup |
| `05-ui.md` | 12 SVG chart components · 13 Overview rebuild + Monitoring card · 14 Fleet page + device drawer · 15 Catalog page |
| `06-ship.md` | 16 Skills, docs, version, live read-only verification + deploy |

Task order is the execution order. Tasks 7–10 depend on Tasks 2–4. Tasks 13–15 depend on Tasks 5, 6, 11 and 12.
