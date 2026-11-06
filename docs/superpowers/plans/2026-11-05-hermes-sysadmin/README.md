# Hermes Sysadmin (AD / WinRM) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the `hermes-sysadmin` Hermes Agent plugin: ~50 typed AD/GPO/RDP/Backup agent tools over WinRM, a tiered approval policy with audit log, workflow skills, `/ad` slash commands, and a Hermes Desktop dashboard matching the approved mockup.

**Architecture:** A pure-Python operation layer (`sysadmin/`) holds a declarative registry of operations; each op maps to one vetted PowerShell script executed on a jump host (a DC) through a pooled pypsrp runspace, with arguments bound as PowerShell parameters (never interpolated). A single `Service.call()` path enforces policy, caching and audit; agent tools, the `pre_tool_call`/`post_tool_call` hooks, slash commands and the FastAPI dashboard backend are thin adapters over it. The Desktop page is one SDK-only ESM file that calls a generic `/ops/{name}` backend route.

**Tech Stack:** Python 3.11+, pypsrp 0.8, pytest, FastAPI (provided by Hermes), PowerShell 5.1 (ActiveDirectory, GroupPolicy, WindowsServerBackup modules) on the target, Hermes Desktop plugin SDK (React via `jsx()`), Node for syntax checks, `pwsh` (macOS) for script parse checks.

**Spec:** `docs/superpowers/specs/2026-11-05-hermes-sysadmin-ad-design.md`
**Approved UI:** `docs/superpowers/mockups/dashboard.html`

## Global Constraints

- Plugin id/name: `hermes-sysadmin` (catalog name, event namespace, plugin-data namespace, API mount `/api/plugins/hermes-sysadmin/`).
- `manifest_version: 2`, `requires_hermes: ">=0.22.2"`, `version: "0.1.0"`, `license: MIT`.
- Python runtime ≥ 3.11 (Hermes). Dev venv: `uv venv --python 3.11 .venv`.
- Runtime dependency: `pypsrp>=0.8.1,<0.9` only. Dev: `pytest>=8,<9`, `fastapi>=0.110,<1`, `httpx>=0.27,<1`, `pyyaml>=6,<7`. Every dependency has an upper bound.
- Hermes imports allowed (public API only): `hermes_cli.config`, `hermes_cli.plugin_events`, `plugins.plugin_storage`, `agent.secret_scope`. Always import them lazily inside functions and tolerate `ImportError` so unit tests run without Hermes.
- Secrets are read only via `agent.secret_scope.get_secret("SYSADMIN_WINRM_PASSWORD", None)`. Never read `.env`, `auth.json` or credential stores.
- User input is passed to PowerShell only via `add_parameter`. The only script that interpolates text is `ad_powershell` (escape hatch, H-tier, off by default).
- Tool handlers never raise; they return a JSON string `{"ok": true, "data": ...}` or `{"ok": false, "error": {"type", "message", "hint", ...}}`.
- Tiers: `R` read, `W` write, `H` high-risk, `P` protected (always blocked). Modes: `strict` (default), `permissive`, `read-only`.
- Passwords never appear in audit rows, logs or previews. Keys redacted: `password`, `new_password`.
- Desktop JS: one ESM file `desktop/plugin.js`; imports only `react`, `react/jsx-runtime`, `@hermes/plugin-sdk`; no JSX syntax, no `eval`, no DOM APIs (`document.*`, `window.*` except via SDK); all colours via `var(--ui-*)`.
- Commit messages end with: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

## File Map

```
/                                   (repo root == plugin root)
├── plugin.yaml                     manifest v2                                  [P2]
├── __init__.py                     register(ctx)                                [P2]
├── pytest.ini, requirements-dev.txt, .gitignore                                 [P1]
├── LICENSE, README.md, CHANGELOG.md                                             [P10]
├── sysadmin/
│   ├── __init__.py                 PLUGIN_ID, __version__                       [P1]
│   ├── errors.py                   typed errors + error_result()                [P1]
│   ├── config.py                   Settings, settings_from(), load_settings()   [P1]
│   ├── transport.py                Transport protocol, PsrpTransport            [P1]
│   ├── runner.py                   Runner, parse_output()                       [P1]
│   ├── registry.py                 Param, Op, OPS, register(), schema/coerce    [P1]
│   ├── policy.py                   Decision, decide(), privileged/protected     [P1]
│   ├── audit.py                    AuditLog, redact(), open_audit()             [P1]
│   ├── service.py                  Service.call/preview/decision                [P1]
│   ├── runtime.py                  get_service(), notify()                      [P1]
│   ├── ops/__init__.py             imports every ops module (registration)      [P2]
│   ├── ops/domain.py               domain/health/search ops                     [P2]
│   ├── ops/users.py                user/group/recycle-bin ops                   [P3]
│   ├── ops/gpo.py                  GPO ops                                      [P4]
│   ├── ops/rdp.py                  RDP ops                                      [P5]
│   ├── ops/backup.py               Windows Server Backup ops                    [P6]
│   ├── ops/meta.py                 ad_powershell, sysadmin_audit_log            [P7]
│   ├── tools.py                    register_tools(ctx)                          [P2]
│   ├── hooks.py                    pre_tool_call / post_tool_call               [P2]
│   ├── commands.py                 /ad slash command                            [P7]
│   ├── api.py                      dashboard API logic + confirm contract       [P8]
│   └── scripts/
│       ├── _prelude.ps1            Invoke-Op, Get-HermesFanout, Iso, creds      [P1]
│       └── <op>.ps1                one per op                                   [P2–P7]
├── skills/<name>/SKILL.md          7 workflow skills                            [P7]
├── dashboard/manifest.json         backend mount                                [P8]
├── dashboard/plugin_api.py         FastAPI router                               [P8]
├── desktop/plugin.js               Desktop page                                 [P9]
├── tests/
│   ├── conftest.py                 FakeTransport, FakeRunner, fixtures          [P1]
│   ├── test_*.py                   unit tests per module                        [P1–P9]
│   ├── test_scripts_contract.py    static PS contract lint                      [P2]
│   └── live/test_live.py           opt-in SYSADMIN_LIVE=1                       [P10]
├── scripts/ps_parse_check.ps1      pwsh AST parse of every .ps1                 [P2]
└── .github/workflows/ci.yml        pytest + parse + node --check                [P10]
```

## Shared Interfaces (exact names — every phase relies on these)

```python
# sysadmin/__init__.py
PLUGIN_ID = "hermes-sysadmin"; __version__ = "0.1.0"

# sysadmin/errors.py
class SysadminError(Exception): type: str; hint: str; details: dict; def to_dict(self) -> dict
class NotConfigured, ConnectionFailed, PermissionDenied, NotFound, PolicyBlocked,
      ApprovalRequired, RemoteScriptError, Timeout, InvalidArguments (SysadminError)
ERROR_TYPES: dict[str, type[SysadminError]]          # by .type string
def error_result(exc: BaseException) -> dict          # {"ok": False, "error": {...}}

# sysadmin/config.py
@dataclass(frozen=True) class Settings: host, port, use_https, auth, username, password,
    verify_tls, server_search_base, backup_stale_days, mode, protected_objects: tuple[str,...],
    privileged_groups: tuple[str,...], enable_powershell_escape;  .configured -> bool
def settings_from(raw: Mapping[str, Any], password: str) -> Settings
def load_settings() -> Settings

# sysadmin/transport.py
class Transport(Protocol): def invoke(self, script: str, params: Mapping[str, Any]) -> list[Any]; def close(self) -> None
class PsrpTransport(Transport): def __init__(self, settings: Settings, prelude: str, *, pool_factory=None, ps_factory=None)
class UnconfiguredTransport(Transport)   # invoke() raises NotConfigured

# sysadmin/runner.py
class Runner: def __init__(self, transport: Transport, scripts_dir: Path = SCRIPTS_DIR)
    def run(self, script: str, params: Mapping[str, Any], *, retry: bool = False) -> Any
    def run_text(self, text: str, params: Mapping[str, Any]) -> Any
def parse_output(out: list[Any]) -> Any

# sysadmin/registry.py
@dataclass(frozen=True) class Param: name, type, description, required=False, ps=None, enum=None, default=None, items="string", minimum=None
@dataclass(frozen=True) class Op: name, toolset, tier, script, description, params=(), target=None,
    identities=(), escalate=None, preview=False, post=None, cache_ttl=0.0, inject=None,
    local=None, enabled=None                                   # added in Phase 7
#   target:   Callable[[Mapping], str]                    — human-readable target for audit/confirm
#   escalate: Callable[[Mapping, Settings, Facts], bool]  — True → treat W op as H
#   post:     Callable[[Any, Mapping, Settings], Any]     — Python post-processing of script data
#   inject:   Callable[[Settings], Mapping[str, Any]]     — extra PS params derived from settings (e.g. PrivilegedGroups)
#   local:    Callable[[Service, Mapping], Any]           — run in Python instead of a script (ad_powershell, sysadmin_audit_log)
#   enabled:  Callable[[Settings], bool]                  — False → decide() blocks the op
OPS: dict[str, Op]
def register(op: Op) -> Op
def schema_for(op: Op) -> dict
def coerce_args(op: Op, args: Mapping[str, Any] | None) -> dict
def ps_params(op: Op, args: Mapping[str, Any]) -> dict
def target_of(op: Op, args: Mapping[str, Any]) -> str

# sysadmin/policy.py
@dataclass(frozen=True) class Decision: action: "allow"|"approve"|"block"; tier: str; reason: str; needs_preview: bool = False
class Facts(Protocol): def domain_controllers(self) -> list[str] | None   # None = unknown (fail safe)
def decide(op: Op, args: Mapping, settings: Settings, facts: Facts | None = None) -> Decision
def is_privileged_group(name: str, settings: Settings) -> bool
def is_domain_controller_name(host: str, dcs: Iterable[str]) -> bool

# sysadmin/audit.py
def redact(args: Mapping[str, Any]) -> dict
class AuditLog: def __init__(self, conn: sqlite3.Connection)
    def record(self, *, actor, session, tool, target, tier, decision, result, params) -> None
    def query(self, *, limit=100, actor=None, decision=None) -> list[dict]
def open_audit() -> AuditLog

# sysadmin/service.py
class Service: settings; audit
    def __init__(self, settings, runner, audit, notify=lambda event, payload: None, clock=time.monotonic)
    def call(self, name, args=None, *, actor, session="", approved=False) -> dict
    def preview(self, name, args=None) -> dict
    def decision(self, name, args=None) -> Decision
    def record_denied(self, name, args, *, actor, session, reason) -> None
    def invalidate(self) -> None
    facts: Facts      # lazily resolves DCs via the "ad_dc_list" op (cached 300 s)
# Service.call() audit decision words: "allowed" | "approved" | "confirmed" | "blocked: …" | "denied: …"
# Service.call() actors: "agent" | "dashboard" | "command"

# sysadmin/runtime.py
def get_service() -> Service          # cached per Settings; rebuilt when settings change
def notify(event: str, payload: dict) -> None   # broadcast_plugin_event wrapper, never raises
```

PowerShell script contract (every `sysadmin/scripts/<op>.ps1` except `_prelude.ps1`):

```powershell
param(
    [Parameter(Mandatory)][string]$Identity,   # PS names = CamelCase of the op's Param.name
    [switch]$Preview                           # only on ops with preview=True
)
Invoke-Op {
    # ... return a hashtable / array of hashtables with primitive values only
}
```

- Lists are returned as `@{ items = @( ... ) }` so a single result is never unwrapped into a scalar.
- Dates go through `Iso $value` (UTC ISO-8601 string or `$null`).
- Prelude helpers available to every script: `Iso`, `Get-CnName $dn`, `Get-ParentDn $dn`, `New-HermesPassword`, `ConvertTo-HermesSecure $plain`, `Assert-Hermes $cond $message` (→ `InvalidArguments`), `ConvertTo-LdapValue $v`, `Get-HermesGpo $nameOrGuid`, `Get-XmlText $node`, `Get-HermesFanout`, `Get-HermesTargets` + `Invoke-HermesOne` (added in Phase 5), `$Global:HermesCred`, `$Global:HermesIsDc`, `$Global:HermesLocalDc`.
- AD cmdlets get `-Credential $Global:HermesCred` and GroupPolicy cmdlets get `-Server <this DC>` automatically via `$PSDefaultParameterValues`; scripts must not pass them again.
- Fan-out to other hosts uses `Get-HermesFanout -Computers $c -Script { ... }` and the remote scriptblock must emit `[pscustomobject]@{...}` (never a bare hashtable).
- Write scripts with `preview=True` return `@{ summary = '...'; changes = @(...); current = @{...} }` when `-Preview` is set and make no change.
- No dependency installs: Python deps are declared only in `plugin.yaml` `python_dependencies` (there is deliberately no `pyproject.toml`, so Hermes never tries to build the repo as a package).

## Phases

| # | File | Deliverable |
|---|---|---|
| 1 | [01-foundation.md](01-foundation.md) | Core library: errors, config, transport, runner, registry, policy, audit, service, runtime — fully unit-tested with fakes |
| 2 | [02-integration-domain.md](02-integration-domain.md) | Manifest + `register()` + tools + hooks + domain ops; validated by `hermes plugins validate`; first live call against the DC |
| 3 | [03-users.md](03-users.md) | User, group, lockout, recycle-bin ops |
| 4 | [04-gpo.md](04-gpo.md) | GPO ops |
| 5 | [05-rdp.md](05-rdp.md) | RDP session and host-access ops |
| 6 | [06-backup.md](06-backup.md) | Windows Server Backup ops |
| 7 | [07-meta-commands-skills.md](07-meta-commands-skills.md) | Escape hatch, audit tool, `/ad` command, 7 skills |
| 8 | [08-backend-api.md](08-backend-api.md) | FastAPI backend with confirm contract, overview composite, events |
| 9 | [09-desktop.md](09-desktop.md) | Desktop dashboard (all six tabs, dialogs, status bar, palette, first-run) |
| 10 | [10-ship.md](10-ship.md) | Live tests, CI, README/screenshots, demo, catalog PR |

Phases run in order. Phases 3–5 are independent of each other once Phase 2 is done; Phase 6 reuses the `Get-HermesTargets` / `Invoke-HermesOne` prelude helpers added in Phase 5.

## Prerequisites (user)

- Jump host: **a domain controller** with WinRM HTTPS (5986) or HTTP+NTLM encryption (5985). A DC is required in V1 because GroupPolicy cmdlets cannot take explicit credentials, so the jump host must not need to make a second hop for AD/GPO work.
- Service account with delegated rights (or Domain Admin for the demo lab), and WinRM enabled on member servers that the RDP/backup tabs should reach.
- A test OU, e.g. `OU=HermesTest,DC=corp,DC=example,DC=local`.
- Hermes Agent ≥ 0.22.2 and Hermes Desktop installed locally (present: v0.22.6).
