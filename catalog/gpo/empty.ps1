<# hermes-catalog
id: gpo.empty
title: Empty GPOs
category: Group Policy
description: Group Policy objects whose user and computer versions are both 0, meaning no settings were ever saved in them.
module: inbox:GroupPolicy
target: dc
tier: R
columns: [name, created]
tags: [gpo, group policy, empty, no settings, unused, cleanup, hygiene]
source: In-box GroupPolicy (Get-GPO)
#>
param()
Invoke-Op {
    $rows = @(Get-GPO -All |
        Where-Object { [int64]$_.User.DSVersion -eq 0 -and [int64]$_.Computer.DSVersion -eq 0 } |
        Sort-Object DisplayName |
        ForEach-Object { @{ name = $_.DisplayName; created = (Iso $_.CreationTime) } })
    @{ items = @($rows | Select-Object -First 500); summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500) } }
}
