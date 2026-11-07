<# hermes-catalog
id: events.service_installs
title: New service installs (7045)
category: Event logs
description: Services installed on the computer (System event 7045) with binary path and run-as account. Unexpected entries can indicate persistence or lateral movement.
module: inbox:Microsoft.PowerShell.Diagnostics
target: endpoint
tier: R
columns: [host, service, path, account, time]
tags: [service install, 7045, persistence, psexec, system log, new service]
source: In-box Get-WinEvent -FilterHashtable
params:
  - {name: Days, type: integer, default: 7, minimum: 1, maximum: 365, description: How many days back to look.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$Days = 7)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Days) -Script {
        param($d)
        $ErrorActionPreference = 'Stop'
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 7045; StartTime = (Get-Date).AddDays(-$d) } -MaxEvents 200)
        } catch {
            if ("$($_.FullyQualifiedErrorId)" -like 'NoMatchingEventsFound*') { return }
            throw
        }
        foreach ($e in $events) {
            $p = @($e.Properties)
            [pscustomobject]@{
                service = $(if ($p.Count -gt 0) { "$($p[0].Value)" } else { $null })
                path = $(if ($p.Count -gt 1) { "$($p[1].Value)" } else { $null })
                account = $(if ($p.Count -gt 4) { "$($p[4].Value)" } else { $null })
                time = $e.TimeCreated.ToUniversalTime().ToString('o')
            }
        }
    }
}
