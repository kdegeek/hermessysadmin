# Phase 10 — Live tests, CI, docs, catalog PR, demo

> Part of the [Hermes Sysadmin plan](README.md). Requires Phases 1–9.

**Deliverable:** An opt-in live test suite against the lab domain and GitHub Actions CI. Also README / LICENSE / CHANGELOG with the rule-13 disclosures, a public GitHub repo at a tagged commit, the catalog entry PR to `NousResearch/hermes-agent`, and the ≤ 90 s demo posted on X with the hackathon form submitted.

**Deadline:** submissions close **Nov 11, 5 PM EST**. Tasks 4–6 are outward-facing: confirm with the user before creating the repo, opening the PR or posting.

---

### Task 1: Live test suite (opt-in)

**Files:**
- Create: `tests/live/__init__.py` (empty), `tests/live/test_live.py`
- Modify: `pytest.ini` (marker)

**Interfaces:**
- Consumes: `config.settings_from`, `runtime.build_service`, `Service.call/preview`.
- Env vars:
  - `SYSADMIN_LIVE=1` enables the suite; it is skipped otherwise.
  - `SYSADMIN_LIVE_WRITE=1` adds the write tests.
  - `SYSADMIN_HOST`, `SYSADMIN_USER`, `SYSADMIN_WINRM_PASSWORD`, and optionally `SYSADMIN_PORT`, `SYSADMIN_HTTPS`, `SYSADMIN_VERIFY_TLS`. These are the same variables as `scripts/smoke.py`.
  - `SYSADMIN_TEST_OU` (DN) is required for the write tests.
  - `SYSADMIN_TEST_SERVER` (FQDN of a member server) is optional.

- [ ] **Step 1: Write the suite.** Create `tests/live/test_live.py`:

```python
"""Live tests against a real domain. Read-only unless SYSADMIN_LIVE_WRITE=1.

Write tests only create/modify objects named zz-hermes-test-* inside SYSADMIN_TEST_OU and
always clean up, even on failure.
"""

import json
import os
import uuid

import pytest

from sysadmin import ops  # noqa: F401
from sysadmin.config import settings_from
from sysadmin.runtime import build_service

pytestmark = [
    pytest.mark.live,
    pytest.mark.skipif(os.environ.get("SYSADMIN_LIVE") != "1", reason="set SYSADMIN_LIVE=1 to run live tests"),
]
WRITE = os.environ.get("SYSADMIN_LIVE_WRITE") == "1"
TEST_OU = os.environ.get("SYSADMIN_TEST_OU", "")
SERVER = os.environ.get("SYSADMIN_TEST_SERVER", "")


@pytest.fixture(scope="module")
def svc():
    raw = {
        "host": os.environ.get("SYSADMIN_HOST", ""),
        "username": os.environ.get("SYSADMIN_USER", ""),
        "port": os.environ.get("SYSADMIN_PORT", "5986"),
        "use_https": os.environ.get("SYSADMIN_HTTPS", "true"),
        "verify_tls": os.environ.get("SYSADMIN_VERIFY_TLS", "true"),
        "mode": "strict",
    }
    service = build_service(settings_from(raw, os.environ.get("SYSADMIN_WINRM_PASSWORD", "")))
    yield service
    service.runner.close()


def ok(result):
    assert result["ok"], result.get("error")
    return result["data"]


def call(svc, name, args=None, approved=False):
    return svc.call(name, args or {}, actor="agent", session="live-tests", approved=approved)


@pytest.mark.parametrize(
    "name, args",
    [
        ("ad_connection_test", {}),
        ("ad_dc_list", {}),
        ("ad_domain_overview", {}),
        ("ad_dc_health", {}),
        ("ad_search", {"query": "Domain Admins"}),
        ("ad_user_list", {"status": "locked", "limit": 5}),
        ("ad_group_get", {"identity": "Domain Admins"}),
        ("ad_recycle_bin_list", {"limit": 5}),
        ("gpo_list", {}),
        ("gpo_health", {}),
        ("gpo_report", {"identity": "Default Domain Policy"}),
        ("gpo_backups", {}),
        ("rdp_sessions", {}),
        ("rdp_host_status", {}),
        ("backup_status", {}),
        ("sysadmin_audit_log", {"limit": 5}),
    ],
)
def test_reads(svc, name, args):
    ok(call(svc, name, args))


def test_domain_controllers_are_healthy_enough(svc):
    data = ok(call(svc, "ad_dc_health"))
    assert data["items"], "no DCs returned"
    assert data["status"] in ("ok", "warn"), data


@pytest.mark.skipif(not SERVER, reason="set SYSADMIN_TEST_SERVER for host-specific reads")
@pytest.mark.parametrize("name", ["backup_versions", "backup_jobs", "rdp_connect_file"])
def test_host_reads(svc, name):
    ok(call(svc, name, {"host": SERVER}))


def test_writes_are_refused_without_approval(svc):
    out = call(svc, "ad_user_unlock", {"identity": "zz-hermes-test-nobody"})
    assert out["error"]["type"] == "ApprovalRequired"


def test_protected_objects_are_blocked_live(svc):
    out = call(svc, "ad_user_disable", {"identity": "krbtgt"}, approved=True)
    assert out["error"]["type"] == "PolicyBlocked"


@pytest.mark.skipif(not (WRITE and TEST_OU), reason="set SYSADMIN_LIVE_WRITE=1 and SYSADMIN_TEST_OU")
def test_user_lifecycle(svc):
    sam = f"zz-hermes-test-{uuid.uuid4().hex[:6]}"
    try:
        created = ok(call(svc, "ad_user_create", {"sam": sam, "given_name": "Hermes", "surname": "Test", "ou": TEST_OU}, approved=True))
        assert created.get("password"), "generated password must be returned once"
        ok(call(svc, "ad_user_disable", {"identity": sam, "note": "live test"}, approved=True))
        assert ok(call(svc, "ad_user_get", {"identity": sam}))["enabled"] is False
        ok(call(svc, "ad_user_enable", {"identity": sam}, approved=True))
        reset = ok(call(svc, "ad_user_reset_password", {"identity": sam}, approved=True))
        logged = json.dumps(svc.audit.query(limit=20))
        assert created["password"] not in logged and reset["password"] not in logged
        preview = ok(svc.preview("ad_user_delete", {"identity": sam}))
        assert preview.get("summary")
    finally:
        call(svc, "ad_user_delete", {"identity": sam}, approved=True)


@pytest.mark.skipif(not (WRITE and TEST_OU), reason="set SYSADMIN_LIVE_WRITE=1 and SYSADMIN_TEST_OU")
def test_gpo_lifecycle(svc):
    name = f"zz-hermes-test-gpo-{uuid.uuid4().hex[:6]}"
    try:
        ok(call(svc, "gpo_create", {"name": name, "comment": "live test"}, approved=True))
        backup = ok(call(svc, "gpo_backup", {"identity": name}, approved=True))
        ok(call(svc, "gpo_link", {"identity": name, "target": TEST_OU}, approved=True))
        linked = ok(call(svc, "gpo_get", {"identity": name}))
        assert any(link["target"].lower() == TEST_OU.lower() for link in linked["links"])
        ok(call(svc, "gpo_set_link", {"identity": name, "target": TEST_OU, "enabled": False}, approved=True))
        ok(call(svc, "gpo_unlink", {"identity": name, "target": TEST_OU}, approved=True))
        ok(svc.preview("gpo_restore", {"identity": name, "backup_id": backup["backup_id"]}))
    finally:
        call(svc, "gpo_delete", {"identity": name}, approved=True)
```

- [ ] **Step 2: Register the marker.** Append to `pytest.ini`:

```ini
markers =
    live: tests that talk to a real domain (opt-in via SYSADMIN_LIVE=1)
```

- [ ] **Step 3: Run the suites.**

  First check that the live suite skips by default. Run `.venv/bin/pytest`. Expected: all pass, and the live tests show as `skipped`.

  Then run it against the lab:
  ```bash
  export SYSADMIN_LIVE=1 SYSADMIN_HOST=dc01.corp.example.local SYSADMIN_USER='CORP\svc-hermes'
  read -rs SYSADMIN_WINRM_PASSWORD && export SYSADMIN_WINRM_PASSWORD
  .venv/bin/pytest tests/live -v
  SYSADMIN_LIVE_WRITE=1 SYSADMIN_TEST_OU='OU=HermesTest,DC=corp,DC=example,DC=local' \
    SYSADMIN_TEST_SERVER='<member server FQDN>' .venv/bin/pytest tests/live -v
  ```
  Replace the host, user, OU and `<member server FQDN>` with lab values first.

  Expected: every test passes, and the test OU contains no `zz-hermes-test-*` leftovers. Fix any script that fails before moving on; the live suite is the end-to-end proof for the demo.

- [ ] **Step 4: Commit.**

```bash
git add tests/live pytest.ini
git commit -m "test: opt-in live suite against a real domain

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: CI

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Write the workflow.** Create `.github/workflows/ci.yml`:

```yaml
name: ci
on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        python: ["3.11", "3.12"]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: ${{ matrix.python }}
      - uses: actions/setup-node@v4
        with:
          node-version: "20"
      - name: Install dependencies
        run: |
          python -m pip install --upgrade pip
          pip install -r requirements-dev.txt "pypsrp>=0.8.1,<0.9"
      - name: PowerShell available
        run: pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
      - name: Unit, contract, parse and desktop lint tests
        run: python -m pytest -q
      - name: Desktop syntax check
        run: node --check desktop/plugin.js
```

GitHub's Ubuntu runners ship `pwsh`, so `test_all_scripts_parse` runs in CI instead of skipping. The Phase 9 desktop lint (`tests/test_desktop.py`) runs inside pytest.

- [ ] **Step 2: Lint the workflow locally.**

  Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo ok`

  Expected: `ok`. The real check happens once the repo is pushed (Task 4 Step 3).

- [ ] **Step 3: Commit.**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: pytest, PowerShell parse checks and desktop lint

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: README, LICENSE, CHANGELOG

**Files:**
- Create: `README.md`, `LICENSE`, `CHANGELOG.md`
- Uses: `docs/screenshots/*.png` (captured in Phase 9 Task 6)

- [ ] **Step 1: `LICENSE`.** Write the standard MIT License text, `Copyright (c) 2026 Nate Crawford`.

- [ ] **Step 2: `CHANGELOG.md`.**

```markdown
# Changelog

## 0.1.0 — 2026-11-11

First release (Nous Research Hermes Agent Plugin Hackathon).

- 56 typed tools across six toolsets: domain, users, Group Policy, RDP, Windows Server Backup, meta.
- Tiered safety policy (read / write / high-risk / protected), strict, permissive and read-only modes, privileged-group and domain-controller escalation, protected objects.
- Approval through Hermes's `pre_tool_call` hook, with previews for high-risk changes; local SQLite audit log with password redaction.
- Seven workflow skills and the `/ad` slash command.
- Hermes Desktop dashboard: Overview, Users, Group Policy, Remote Access, Backups, Audit.
```

- [ ] **Step 3: `README.md`.** Write the README with this exact structure and content. Fill in the real tool count from `python -c "from sysadmin import ops; from sysadmin.registry import OPS; print(len(OPS))"`.

````markdown
# Hermes Sysadmin · Active Directory

Manage an on-prem Active Directory domain from Hermes Agent over WinRM. It covers users, groups and lockouts, Group Policy, RDP sessions and access, and Windows Server Backup. Every change goes through typed tools with tiered approvals, protected objects and a local audit log. The plugin also ships workflow skills, `/ad` commands and a Hermes Desktop dashboard.

![Overview](docs/screenshots/overview.png)

## What you get

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

- Hermes Agent ≥ 0.22.2. Hermes Desktop is needed for the dashboard.
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

Open **Settings → Plugins → hermes-sysadmin** and set the jump host, username and password. The password is stored in Hermes secrets. Then click **Test connection** on the dashboard's first-run card.

Settings: `host`, `port`, `use_https`, `auth` (ntlm/kerberos), `username`, `password` (secret `SYSADMIN_WINRM_PASSWORD`), `verify_tls`, `server_search_base`, `backup_stale_days`, `mode`, `protected_objects`, `privileged_groups`, `enable_powershell_escape`.

## Safety model

| Tier | Examples | strict (default) | permissive | read-only |
|---|---|---|---|---|
| Read | list, get, report, status | runs | runs | runs |
| Write | unlock, reset password, link GPO, log off, start backup | approval | runs | blocked |
| High-risk | delete, privileged-group change, GPO delete/restore, links at domain root / DCs / sites, RDP or Remote Desktop Users on a DC, disabling NLA, backup policy, raw PowerShell | approval with preview | approval with preview | blocked |
| Protected | krbtgt, Administrator, your denylist | blocked | blocked | blocked |

- The agent asks through Hermes's own approval prompt. High-risk approvals show a preview, and an "always allow" never carries over to the next high-risk call.
- The dashboard requires a confirm dialog. High-risk changes also make you type the object's name. The API refuses writes that lack that confirmation.
- Unattended runs (cron, gateway) cannot approve writes; tools return a clear "needs approval" error.
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

## Screenshots

| Users | Group Policy | Remote Access |
|---|---|---|
| ![](docs/screenshots/users.png) | ![](docs/screenshots/gpo.png) | ![](docs/screenshots/rdp.png) |
| **Backups** | **Audit** | |
| ![](docs/screenshots/backups.png) | ![](docs/screenshots/audit.png) | |

## License

MIT
````

- [ ] **Step 4: Verify the README claims match the code.**

  Run:
  ```bash
  .venv/bin/python -c "from sysadmin import ops; from sysadmin.registry import OPS; print(len(OPS))"
  ls docs/screenshots
  ```

  Expected: the count printed matches the CHANGELOG ("56 typed tools"; if it differs, update both files), and all six PNGs are present.

- [ ] **Step 5: Commit.**

```bash
git add README.md LICENSE CHANGELOG.md docs/screenshots
git commit -m "docs: README with safety model and disclosures, license, changelog

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Publish the repository (confirm with the user first)

- [ ] **Step 1: Final local gate.**

  Run:
  ```bash
  .venv/bin/pytest
  node --check desktop/plugin.js
  hermes plugins validate "$(git rev-parse --show-toplevel)" --install-deps
  hermes plugins doctor "$(git rev-parse --show-toplevel)" --ci
  git status --short
  ```

  Expected:
  - All tests pass and the `node --check` is clean.
  - `validate` passes, including the `security scan`, `desktop surface` and `no core override` checks. Read every warning.
  - `git status` is clean.

- [ ] **Step 2: Create the public repo.** Ask the user first; this publishes the code.

  ```bash
  gh repo create hermessysadmin --public --source . --remote origin \
    --description "Hermes Agent plugin: Active Directory, Group Policy, RDP and Windows Server Backup over WinRM"
  git push -u origin main
  ```

- [ ] **Step 3: Wait for CI to pass, then tag the release.**

  ```bash
  gh run list --limit 1          # wait for the ci run on main to finish
  gh run view --exit-status "$(gh run list --limit 1 --json databaseId -q '.[0].databaseId')"
  git tag -a v0.1.0 -m "hermes-sysadmin 0.1.0" && git push origin v0.1.0
  git rev-parse HEAD             # the 40-char SHA for the catalog entry
  ```

  Expected: the run's status is `completed` with conclusion `success`.

- [ ] **Step 4: Install from GitHub in a clean profile to prove the published tree works.**

  ```bash
  hermes -p sysadmin-check plugins install "$(gh repo view --json nameWithOwner -q .nameWithOwner)" --enable
  hermes -p sysadmin-check plugins list | grep hermes-sysadmin
  ```

  Expected: the plugin is listed as enabled. If this Hermes build does not support `-p` profiles, use `HERMES_HOME=$(mktemp -d) hermes plugins install ...` instead.

---

### Task 5: Catalog entry PR (confirm with the user first)

**Files (in a fork of `NousResearch/hermes-agent`):**
- Create: `plugin-catalog/hermes-sysadmin.yaml`

- [ ] **Step 1: Fork and branch.**

  ```bash
  gh repo fork NousResearch/hermes-agent --clone --remote ~/src/hermes-agent-fork
  cd ~/src/hermes-agent-fork && git checkout -b catalog/hermes-sysadmin
  ```

- [ ] **Step 2: Write the entry.** Substitute `<owner>` (the GitHub user) and `<sha>` (from Task 4 Step 3) everywhere. Set `requires_env` to exactly what `hermes plugins validate` reports for the plugin; leave it empty if validate lists none, because the password is a `config_schema` secret.

```yaml
name: hermes-sysadmin
repo: https://github.com/<owner>/hermessysadmin
sha: "<sha>"
version: "0.1.0"
title: Sysadmin · Active Directory
description: "Manage an on-prem Active Directory domain over WinRM: users, groups and lockouts, Group Policy (health, reports, RSoP, link/enforce, security filtering, backup/restore), RDP sessions and access, and Windows Server Backup. 56 typed tools with tiered approvals (write / high-risk with preview / protected objects), strict, permissive and read-only modes, a local audit log, seven workflow skills, /ad commands and a Hermes Desktop dashboard. Disclosure — connects over WinRM (5985/5986) to one configured domain controller, which runs vetted PowerShell scripts with bound parameters and reaches member servers you target with the same explicit credential; the WinRM password is read only via Hermes secrets and never logged; writes an audit log (SQLite) in the plugin's data folder and GPO backups on the DC under %ProgramData%\\HermesSysadmin\\GpoBackups; the optional ad_powershell tool (off by default, high-risk every call) runs arbitrary PowerShell on the DC after approval; no local shell, no telemetry, no background processes."
maintainer: <owner>
tier: community
category: tools
requires_hermes: ">=0.22.2"
docs_url: https://github.com/<owner>/hermessysadmin/blob/<sha>/README.md
readme: true
platforms: [linux, macos, windows]
screenshots:
  - https://raw.githubusercontent.com/<owner>/hermessysadmin/<sha>/docs/screenshots/overview.png
  - https://raw.githubusercontent.com/<owner>/hermessysadmin/<sha>/docs/screenshots/users.png
  - https://raw.githubusercontent.com/<owner>/hermessysadmin/<sha>/docs/screenshots/gpo.png
  - https://raw.githubusercontent.com/<owner>/hermessysadmin/<sha>/docs/screenshots/rdp.png
  - https://raw.githubusercontent.com/<owner>/hermessysadmin/<sha>/docs/screenshots/backups.png
  - https://raw.githubusercontent.com/<owner>/hermessysadmin/<sha>/docs/screenshots/audit.png
known_issues:
  - "The WinRM jump host must be a domain controller (Group Policy cmdlets cannot take explicit credentials)."
  - "Unattended runs (cron, messaging gateway) cannot approve writes; read tools still work."
  - "Restores are out of scope; the backup-recovery-guide skill walks through them."
capabilities:
  provides_tools:
    # paste the exact, sorted provides_tools list from plugin.yaml
  provides_hooks: [pre_tool_call, post_tool_call]
  provides_middleware: []
  requires_env: []
```

- [ ] **Step 3: Paste the tool list and check it.**

  Run:
  ```bash
  python3 - <<'EOF'
  import yaml, pathlib
  plugin = yaml.safe_load(pathlib.Path("<path to hermessysadmin>/plugin.yaml").read_text())
  entry = yaml.safe_load(pathlib.Path("plugin-catalog/hermes-sysadmin.yaml").read_text())
  assert sorted(entry["capabilities"]["provides_tools"]) == sorted(plugin["provides_tools"]), "tool lists differ"
  assert len(entry["sha"]) == 40
  print("catalog entry matches plugin.yaml")
  EOF
  ```

  Expected: `catalog entry matches plugin.yaml`. Then run the catalog's own tests if the fork has them (`python -m pytest tests -k catalog -q`).

- [ ] **Step 4: Open the PR.** Ask the user first.

  ```bash
  git add plugin-catalog/hermes-sysadmin.yaml
  git commit -m "plugin-catalog: add hermes-sysadmin

  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
  git push -u origin catalog/hermes-sysadmin
  gh pr create --repo NousResearch/hermes-agent --title "plugin-catalog: add hermes-sysadmin (Active Directory over WinRM)" --body-file /tmp/hermes-sysadmin-pr.md
  ```

  Write `/tmp/hermes-sysadmin-pr.md` first. It contains:
  - What the plugin does (README intro).
  - The surfaces it uses: tools, the `pre_tool_call`/`post_tool_call` hooks, `register_skill`, `register_command`, the dashboard backend and the Desktop SDK page.
  - The disclosure list from the README.
  - The safety model table.
  - Two screenshots.
  - That it is a hackathon submission.
  - A last line: `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

- [ ] **Step 5: Wait for the catalog CI to pass.** Fix any validation failure by pushing a fix to the plugin repo, updating `sha`, `docs_url` and the screenshot URLs, and pushing the PR branch again.

---

### Task 6: Demo video (≤ 90 s), X post, hackathon form

This is a manual checklist for the user. Record on the lab domain with Hermes Desktop.

- [ ] **Step 1: Prepare the lab state for the story:**
  - `zz-demo-bob` locked out by a stale disconnected RDP session on a member server.
  - An unlinked "Screen Lock" GPO.
  - One server whose system-state backup is over 7 days old.

- [ ] **Step 2: Record**, following spec §12 (target 80 s):

| Time | Shot |
|---|---|
| 0–8 s | Overview tab: KPIs, red backup tile, DC health. |
| 8–30 s | Chat: "Why does bob keep getting locked out?" The `lockout-triage` skill finds the source host and the stale session, and an approval prompt appears for log off + unlock. Approve. |
| 30–50 s | Chat: "Roll out the screensaver-lock GPO to the Finance OU." The `gpo-change` skill backs up, shows the link approval, runs gpupdate on a test host, and RSoP shows it applied. |
| 50–62 s | Group Policy tab shows the new link, and the Audit tab shows the agent's entries. |
| 62–75 s | Backups tab: red card → Back up now → progress bar. |
| 75–80 s | Users tab: try deleting `krbtgt`, which is blocked as a protected object. End card with the repo URL. |

- [ ] **Step 3: Post on X** (with the user's account) and tag @NousResearch: one sentence, the video and the repo link. Ask the user to review the text before posting.

- [ ] **Step 4: Submit the hackathon form** at http://form.typeform.com/to/FwJLvOln with the repo URL, the catalog PR URL and the X post URL. **Deadline Nov 11, 5 PM EST.**
