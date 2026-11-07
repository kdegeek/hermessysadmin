<# hermes-catalog
id: events.dc_errors
title: Directory Service and DFS Replication errors on DCs
category: Event logs
description: Errors (and optionally warnings) from the Directory Service and DFS Replication logs on every domain controller, grouped by DC, log and event ID with a count, the latest time and the newest message (trimmed to 300 characters). Points at AD replication, database and SYSVOL replication problems.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [host, log, id, level, count, last, message]
tags: [directory service, dfsr, dfs replication, ntds, replication errors, sysvol, domain controller, 2042, 1311, 4012, 2213]
source: In-box Get-WinEvent -FilterHashtable run locally on each DC through the fan-out
params:
  - {name: Hours, type: integer, default: 72, minimum: 1, maximum: 720, description: How many hours back to look.}
  - {name: IncludeWarnings, type: boolean, default: false, description: Also include warning events.}
#>
param([int]$Hours = 72, [bool]$IncludeWarnings = $false)
Invoke-Op {
    $dcs = @(Get-ADDomainController -Filter * | ForEach-Object { $_.HostName } | Where-Object { $_ })
    $fan = Invoke-HermesCatalogFanout -Computers $dcs -ArgumentList @($Hours, $IncludeWarnings) -Script {
        param($h, $warn)
        $ErrorActionPreference = 'Stop'
        $levels = @(1, 2)
        if ($warn) { $levels += 3 }
        $since = (Get-Date).AddHours(-$h)
        foreach ($log in @('Directory Service', 'DFS Replication')) {
            try {
                $events = @(Get-WinEvent -FilterHashtable @{ LogName = $log; Level = $levels; StartTime = $since } -MaxEvents 1000)
            } catch {
                if ("$($_.FullyQualifiedErrorId)" -like 'NoMatching*') { continue }
                throw
            }
            $groups = @{}
            # Newest first, so the first event seen per ID gives the latest time and message.
            foreach ($e in $events) {
                $key = "$([int]$e.Id)"
                if (-not $groups.ContainsKey($key)) {
                    $m = "$($e.Message)" -replace '\s+', ' '
                    if ($m.Length -gt 300) { $m = $m.Substring(0, 300) }
                    $groups[$key] = @{ log = $log; id = [int]$e.Id; level = "$($e.LevelDisplayName)"; count = 0; last = $e.TimeCreated.ToUniversalTime().ToString('o'); message = $m; capped = ($events.Count -ge 1000) }
                }
                $groups[$key]['count']++
            }
            foreach ($g in $groups.Values) { [pscustomobject]$g }
        }
    }
    $cappedDcs = @($fan.items | Where-Object { $_['capped'] } | ForEach-Object { $_['host'] } | Sort-Object -Unique)
    $rows = @($fan.items | Sort-Object { $_['count'] } -Descending | ForEach-Object { @{ host = $_['host']; log = $_['log']; id = $_['id']; level = $_['level']; count = $_['count']; last = $_['last']; message = $_['message'] } })
    @{ items = @($rows | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); dcs = $dcs.Count; dcs_ok = $fan.summary.ok; dcs_failed = $fan.summary.failed; hours = $Hours; capped_dcs = $cappedDcs } }
}
