<# hermes-catalog
id: gpo.processing_errors
title: Group Policy processing errors
category: Group Policy
description: Group Policy errors (and optionally warnings) on each computer from the Group Policy operational log and the System log, newest first. Typical causes are an unreachable domain controller, slow links, unreadable SYSVOL files and failing client-side extensions. Messages are trimmed to 300 characters.
module: inbox:Microsoft.PowerShell.Diagnostics
target: endpoint
tier: R
columns: [host, time, log, id, level, message]
tags: [group policy, gpo, errors, gpupdate failed, 1058, 1129, 1085, policy not applying, operational log]
source: In-box Get-WinEvent (Microsoft-Windows-GroupPolicy/Operational and System, provider Microsoft-Windows-GroupPolicy)
params:
  - {name: Hours, type: integer, default: 72, minimum: 1, maximum: 720, description: How many hours back to look.}
  - {name: IncludeWarnings, type: boolean, default: false, description: Also list warning events.}
  - {name: Max, type: integer, default: 50, minimum: 1, maximum: 200, description: Most events returned per computer.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$Hours = 72, [bool]$IncludeWarnings = $false, [int]$Max = 50)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Hours, $IncludeWarnings, $Max) -Script {
        param($h, $warn, $max)
        $ErrorActionPreference = 'Stop'
        $levels = @(1, 2)
        if ($warn) { $levels += 3 }
        $since = (Get-Date).AddHours(-$h)
        $events = @()
        foreach ($q in @(
            @{ LogName = 'Microsoft-Windows-GroupPolicy/Operational'; Level = $levels; StartTime = $since },
            @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-GroupPolicy'; Level = $levels; StartTime = $since })) {
            try {
                $events += @(Get-WinEvent -FilterHashtable $q -MaxEvents $max)
            } catch {
                if ("$($_.FullyQualifiedErrorId)" -like 'NoMatching*') { continue }
                throw
            }
        }
        @($events | Sort-Object TimeCreated -Descending | Select-Object -First $max) | ForEach-Object {
            $m = "$($_.Message)" -replace '\s+', ' '
            if ($m.Length -gt 300) { $m = $m.Substring(0, 300) }
            [pscustomobject]@{ time = $_.TimeCreated.ToUniversalTime().ToString('o'); log = "$($_.LogName)"; id = [int]$_.Id; level = "$($_.LevelDisplayName)"; message = $m }
        }
    }
}
