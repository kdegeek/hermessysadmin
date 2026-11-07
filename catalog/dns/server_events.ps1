<# hermes-catalog
id: dns.server_events
title: DNS Server log errors
category: DNS & DHCP
description: Errors (and optionally warnings) from the 'DNS Server' event log on every domain controller, newest first, with the message trimmed to 300 characters. Typical finds are AD zone load failures (4000, 4013), failed zone transfers and update problems. DCs without the DNS Server log appear under errors.
module: inbox:Microsoft.PowerShell.Diagnostics
target: dc
tier: R
columns: [host, time, id, level, message]
tags: [dns, event log, dns server log, errors, 4013, 4000, zone load, warnings]
source: In-box Get-WinEvent -FilterHashtable run locally on each DC through the fan-out
params:
  - {name: Hours, type: integer, default: 72, minimum: 1, maximum: 720, description: How many hours back to look.}
  - {name: IncludeWarnings, type: boolean, default: false, description: Also list warnings.}
  - {name: Max, type: integer, default: 50, minimum: 1, maximum: 200, description: Maximum events returned per DC.}
#>
param([int]$Hours = 72, [bool]$IncludeWarnings = $false, [int]$Max = 50)
Invoke-Op {
    $dcs = @(Get-ADDomainController -Filter * | ForEach-Object { $_.HostName } | Where-Object { $_ })
    $levels = @(1, 2)
    if ($IncludeWarnings) { $levels += 3 }
    $fan = Invoke-HermesCatalogFanout -Computers $dcs -ArgumentList @($Hours, $levels, $Max) -Script {
        param($h, $lv, $max)
        $ErrorActionPreference = 'Stop'
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'DNS Server'; Level = @($lv); StartTime = (Get-Date).AddHours(-$h) } -MaxEvents $max)
        } catch {
            if ("$($_.FullyQualifiedErrorId)" -like 'NoMatchingEventsFound*') { return }
            throw
        }
        foreach ($e in $events) {
            $msg = "$($e.Message)"
            if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) }
            [pscustomobject]@{ time = $e.TimeCreated.ToUniversalTime().ToString('o'); id = [int]$e.Id; level = "$($e.LevelDisplayName)"; message = $msg }
        }
    }
    $rows = @($fan.items | Sort-Object { $_['time'] } -Descending)
    @{ items = @($rows | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); hours = $Hours; dcs = $dcs.Count; dcs_ok = $fan.summary.ok; dcs_failed = $fan.summary.failed } }
}
