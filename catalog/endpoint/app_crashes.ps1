<# hermes-catalog
id: endpoint.app_crashes
title: Application crashes and hangs
category: Endpoint health
description: Application crashes (Application Error 1000) and hangs (Application Hang 1002) from the Application log, grouped by program, most frequent first, with the most common faulting module for crashes. Reads at most 2000 events per computer.
module: inbox:Microsoft.PowerShell.Diagnostics
target: endpoint
tier: R
columns: [host, app, kind, count, last, top_module]
tags: [crash, hang, not responding, application error, 1000, 1002, faulting module, app crash]
source: In-box Get-WinEvent (Application log events 1000 and 1002)
params:
  - {name: Days, type: integer, default: 14, minimum: 1, maximum: 180, description: How many days back to look.}
  - {name: Top, type: integer, default: 20, minimum: 1, maximum: 100, description: Most programs to return per computer.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$Days = 14, [int]$Top = 20)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Days, $Top) -Script {
        param($days, $top)
        $events = @()
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error', 'Application Hang'; Id = 1000, 1002; StartTime = (Get-Date).AddDays(-$days) } -MaxEvents 2000 -ErrorAction Stop)
        } catch {
            if ("$($_.FullyQualifiedErrorId)" -notmatch 'NoMatchingEventsFound') { throw }
        }
        $rows = foreach ($e in $events) {
            $p = @($e.Properties)
            [pscustomobject]@{ app = if ($p.Count) { "$($p[0].Value)" } else { '(unknown)' }
                               kind = if ($e.Id -eq 1000) { 'crash' } else { 'hang' }
                               module = if ($e.Id -eq 1000 -and $p.Count -gt 3) { "$($p[3].Value)" } else { '' }
                               time = $e.TimeCreated }
        }
        @($rows) | Where-Object { $_ } | Group-Object app, kind | Sort-Object Count -Descending | Select-Object -First $top | ForEach-Object {
            $g = @($_.Group)
            $mod = @($g | Where-Object { $_.module } | Group-Object module | Sort-Object Count -Descending | Select-Object -First 1)
            $last = ($g | Sort-Object time -Descending | Select-Object -First 1).time
            [pscustomobject]@{ app = $g[0].app; kind = $g[0].kind; count = $_.Count
                               last = $last.ToUniversalTime().ToString('o')
                               top_module = if ($mod.Count) { "$($mod[0].Name)" } else { '' } }
        }
    }
}
