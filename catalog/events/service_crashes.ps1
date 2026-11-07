<# hermes-catalog
id: events.service_crashes
title: Unexpected service terminations
category: Event logs
description: Services that terminated unexpectedly (System 7031, where Windows took a recovery action, and 7034), grouped per computer and service with a count and the latest time, most crashes first. A service that keeps crashing is usually a faulty update, driver or configuration.
module: inbox:Microsoft.PowerShell.Diagnostics
target: endpoint
tier: R
columns: [host, service, crashes, last, event_ids]
tags: [service crash, terminated unexpectedly, 7031, 7034, service control manager, stability, services]
source: In-box Get-WinEvent -FilterHashtable (System, Service Control Manager 7031 and 7034)
params:
  - {name: Hours, type: integer, default: 168, minimum: 1, maximum: 720, description: How many hours back to look.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$Hours = 168)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Hours) -Script {
        param($h)
        $ErrorActionPreference = 'Stop'
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7031, 7034; StartTime = (Get-Date).AddHours(-$h) } -MaxEvents 1000)
        } catch {
            if ("$($_.FullyQualifiedErrorId)" -like 'NoMatchingEventsFound*') { return }
            throw
        }
        $groups = @{}
        foreach ($e in $events) {
            $name = "$(@($e.Properties)[0].Value)"
            if (-not $name) { $name = '(unknown)' }
            $t = $e.TimeCreated.ToUniversalTime().ToString('o')
            if (-not $groups.ContainsKey($name)) { $groups[$name] = @{ service = $name; crashes = 0; last = $t; ids = @{} } }
            $groups[$name]['crashes']++
            $groups[$name]['ids']["$([int]$e.Id)"] = $true
            if ($t -gt $groups[$name]['last']) { $groups[$name]['last'] = $t }
        }
        foreach ($g in @($groups.Values | Sort-Object { $_['crashes'] } -Descending | Select-Object -First 200)) {
            [pscustomobject]@{ service = $g['service']; crashes = $g['crashes']; last = $g['last']; event_ids = (@($g['ids'].Keys | Sort-Object) -join ', ') }
        }
    }
}
