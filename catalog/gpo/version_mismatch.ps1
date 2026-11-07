<# hermes-catalog
id: gpo.version_mismatch
title: GPO AD/SYSVOL version mismatch
category: Group Policy
description: GPOs whose version number in Active Directory differs from the version in SYSVOL (user or computer side). A mismatch usually means SYSVOL and AD replication are out of step, and clients may apply stale settings.
module: inbox:GroupPolicy
target: dc
tier: R
columns: [name, scope, ad, sysvol]
tags: [gpo, group policy, version, mismatch, sysvol, replication, gpt.ini, out of sync]
source: In-box GroupPolicy (Get-GPO DSVersion and SysvolVersion)
#>
param()
Invoke-Op {
    $rows = @()
    foreach ($g in @(Get-GPO -All | Sort-Object DisplayName)) {
        if ([int64]$g.User.DSVersion -ne [int64]$g.User.SysvolVersion) {
            $rows += @{ name = $g.DisplayName; scope = 'User'; ad = [int64]$g.User.DSVersion; sysvol = [int64]$g.User.SysvolVersion }
        }
        if ([int64]$g.Computer.DSVersion -ne [int64]$g.Computer.SysvolVersion) {
            $rows += @{ name = $g.DisplayName; scope = 'Computer'; ad = [int64]$g.Computer.DSVersion; sysvol = [int64]$g.Computer.SysvolVersion }
        }
    }
    @{ items = @($rows | Select-Object -First 500); summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500) } }
}
