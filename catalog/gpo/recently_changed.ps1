<# hermes-catalog
id: gpo.recently_changed
title: Recently changed GPOs
category: Group Policy
description: GPOs whose Active Directory object changed in the last N days, newest first, with creation time, status, version numbers and WMI filter. The change time also moves when a GPO's permissions, status or WMI filter change; linking or unlinking a GPO changes the OU, not the GPO, so it does not show here. Deleted GPOs are not listed.
module: inbox:GroupPolicy
target: dc
tier: R
columns: [name, modified, created, new, status, user_version, computer_version, wmi_filter]
tags: [gpo, group policy, changed, modified, recent, audit, what changed, version]
source: In-box GroupPolicy (Get-GPO -All ModificationTime)
params:
  - {name: Days, type: integer, default: 7, minimum: 1, maximum: 365, description: List GPOs changed within this many days.}
#>
param([int]$Days = 7)
Invoke-Op {
    $cut = (Get-Date).AddDays(-$Days)
    $all = @(Get-GPO -All)
    $rows = @($all | Where-Object { $_.ModificationTime -and $_.ModificationTime -ge $cut } | Sort-Object ModificationTime -Descending | ForEach-Object {
        @{
            name = $_.DisplayName
            modified = (Iso $_.ModificationTime)
            created = (Iso $_.CreationTime)
            new = ($_.CreationTime -and $_.CreationTime -ge $cut)
            status = "$($_.GpoStatus)"
            user_version = "AD $($_.User.DSVersion) / SYSVOL $($_.User.SysvolVersion)"
            computer_version = "AD $($_.Computer.DSVersion) / SYSVOL $($_.Computer.SysvolVersion)"
            wmi_filter = $(if ($_.WmiFilter) { $_.WmiFilter.Name } else { $null })
        }
    })
    @{ items = @($rows | Select-Object -First 500); summary = @{ total = $rows.Count; gpos = $all.Count; days = $Days; truncated = ($rows.Count -gt 500) } }
}
