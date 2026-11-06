<# hermes-catalog
id: endpoint.recent_errors
title: Recent errors
category: Endpoint health
description: Critical and error events from the System and Application logs in the last few hours, newest first.
module: inbox:Microsoft.PowerShell.Diagnostics
target: endpoint
tier: R
columns: [host, time, log, source, id, message]
tags: [errors, events, event log, critical, crash]
source: In-box Get-WinEvent
params:
  - {name: Hours, type: integer, default: 24, minimum: 1, maximum: 720, description: How far back to look.}
  - {name: Max, type: integer, default: 25, minimum: 1, maximum: 200, description: Most events to return per computer.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$Hours = 24, [int]$Max = 25)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Hours, $Max) -Script {
        param($hours, $max)
        $since = (Get-Date).AddHours(-$hours)
        $events = foreach ($log in 'System', 'Application') {
            Get-WinEvent -FilterHashtable @{ LogName = $log; Level = 1, 2; StartTime = $since } -MaxEvents $max -ErrorAction SilentlyContinue
        }
        @($events) | Where-Object { $_ } | Sort-Object TimeCreated -Descending | Select-Object -First $max | ForEach-Object {
            $m = "$($_.Message)" -replace '\s+', ' '
            if ($m.Length -gt 300) { $m = $m.Substring(0, 300) }
            [pscustomobject]@{ time = $_.TimeCreated.ToUniversalTime().ToString('o'); log = $_.LogName; source = $_.ProviderName; id = $_.Id; message = $m }
        }
    }
}
