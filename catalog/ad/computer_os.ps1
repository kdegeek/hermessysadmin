<# hermes-catalog
id: ad.computer_os
title: Computers by operating system
category: AD hygiene
description: Computer accounts grouped by the operating system and build recorded in AD, with total, enabled and recently active counts and a support label. The label is a rough guide from the name and build only (out of support, ending soon, supported or unknown for non-Windows and blank entries); it does not know about Extended Security Updates or LTSC editions, so check the vendor lifecycle before acting.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [os, version, computers, enabled, active, support]
tags: [operating system, os inventory, windows versions, unsupported os, end of life, eol, legacy, windows 7, server 2012]
source: In-box ActiveDirectory (Get-ADComputer OperatingSystem, OperatingSystemVersion)
params:
  - {name: ActiveDays, type: integer, default: 30, minimum: 1, maximum: 365, description: A computer counts as active if it logged on within this many days.}
#>
param([int]$ActiveDays = 30)
Invoke-Op {
    $cut = (Get-Date).AddDays(-$ActiveDays)
    $groups = @(Get-ADComputer -Filter * -Properties OperatingSystem, OperatingSystemVersion, LastLogonDate |
        Group-Object { "$($_.OperatingSystem)|$($_.OperatingSystemVersion)" })
    $rows = @(foreach ($g in $groups) {
        $first = $g.Group[0]
        $os = "$($first.OperatingSystem)"
        $ver = "$($first.OperatingSystemVersion)"
        $build = 0
        if ($ver -match '\((\d+)\)') { $build = [int]$Matches[1] }
        $support = 'supported'
        if (-not $os -or $os -notlike 'Windows*') { $support = 'unknown' }
        elseif ($os -like '*Windows 2000*' -or $os -like '*Windows XP*' -or $os -like '*Vista*' -or $os -like '*Windows 7*' -or
                $os -like '*Windows 8*' -or $os -like '*Server 2003*' -or $os -like '*Server 2008*' -or $os -like '*Server 2012*' -or
                $os -like '*Windows NT*') { $support = 'out of support' }
        elseif ($os -like '*Windows 10*') { $support = $(if ($os -like '*LTS*') { 'check LTSC build' } else { 'out of support' }) }
        elseif ($os -like '*Windows 11*' -and $build -gt 0 -and $build -lt 22631) { $support = 'out of support' }
        elseif ($os -like '*Server 2016*') { $support = 'ending soon' }
        @{ os = $(if ($os) { $os } else { '(blank)' }); version = $ver; computers = $g.Count
           enabled = @($g.Group | Where-Object { $_.Enabled }).Count
           active = @($g.Group | Where-Object { $_.Enabled -and $_.LastLogonDate -and $_.LastLogonDate -gt $cut }).Count
           support = $support }
    })
    $rows = @($rows | Sort-Object { -[int]$_['computers'] })
    @{ items = @($rows | Select-Object -First 500)
       summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); computers = (@($rows | ForEach-Object { [int]$_['computers'] }) | Measure-Object -Sum).Sum
                    out_of_support_enabled = (@($rows | Where-Object { $_['support'] -eq 'out of support' } | ForEach-Object { [int]$_['enabled'] }) | Measure-Object -Sum).Sum
                    active_days = $ActiveDays } }
}
