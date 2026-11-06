"""hermes-sysadmin — Active Directory, Group Policy, RDP and Windows Server Backup over WinRM.

Install:  hermes plugins install <owner>/hermessysadmin --enable
Dev loop: ln -s "$PWD" ~/.hermes/plugins/hermes-sysadmin && hermes plugins enable hermes-sysadmin
"""

from __future__ import annotations


def register(ctx):
    from .sysadmin import hooks, tools

    tools.register_tools(ctx)
    ctx.register_hook("pre_tool_call", hooks.pre_tool_call)
    ctx.register_hook("post_tool_call", hooks.post_tool_call)
