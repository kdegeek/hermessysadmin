"""hermes-sysadmin — Active Directory, Group Policy, RDP and Windows Server Backup over WinRM.

Install:  hermes plugins install <owner>/hermessysadmin --enable
Dev loop: ln -s "$PWD" ~/.hermes/plugins/hermes-sysadmin && hermes plugins enable hermes-sysadmin
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parent
SKILLS = (
    "onboard-user",
    "offboard-user",
    "lockout-triage",
    "gpo-change",
    "domain-health-check",
    "access-review",
    "backup-recovery-guide",
)


def register(ctx):
    from .sysadmin import commands, hooks, tools

    # Approval gate first: hooks must exist before any tool can be registered.
    ctx.register_hook("pre_tool_call", hooks.pre_tool_call)
    ctx.register_hook("post_tool_call", hooks.post_tool_call)
    tools.register_tools(ctx)
    for name in SKILLS:
        ctx.register_skill(name, ROOT / "skills" / name / "SKILL.md")
    ctx.register_command(
        "ad",
        commands.make_command(ctx),
        description="Active Directory quick commands (no LLM round-trip)",
        args_hint="status | user <name> | unlock <name> | sessions [host] | backups | catalog <query> | run <id> k=v [on H1,H2]",
    )
