<# hermes-catalog
id: events.search
title: Search an event log by ID
category: Event logs
description: Events with a given ID from the System, Application or Security log on each computer, newest first. Messages are trimmed to 300 characters.
module: inbox:Microsoft.PowerShell.Diagnostics
target: endpoint
tier: R
columns: [host, time, id, provider, level, message]
tags: [event log, search, event id, eventvwr, errors, system, application, security]
source: In-box Get-WinEvent -FilterHashtable
params:
  - {name: Log, type: string, enum: [System, Application, Security], default: System, description: Which event log to search.}
  - {name: Id, type: integer, required: true, minimum: 0, maximum: 65535, description: Event ID to look for.}
  - {name: Hours, type: integer, default: 24, minimum: 1, maximum: 720, description: How many hours back to look.}
  - {name: Max, type: integer, default: 50, minimum: 1, maximum: 500, description: Maximum events returned per computer.}
#>
param([string[]]$Computers = @(), [string]$Ou, [string]$Log = 'System', [int]$Id, [int]$Hours = 24, [int]$Max = 50)
Invoke-Op {
    if (@('System', 'Application', 'Security') -cnotcontains $Log) { throw 'InvalidArguments: Log must be System, Application or Security' }
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Log, $Id, $Hours, $Max) -Script {
        param($log, $id, $h, $max)
        $ErrorActionPreference = 'Stop'
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = $log; Id = $id; StartTime = (Get-Date).AddHours(-$h) } -MaxEvents $max)
        } catch {
            if ("$($_.FullyQualifiedErrorId)" -like 'NoMatchingEventsFound*') { return }
            throw
        }
        foreach ($e in $events) {
            $m = "$($e.Message)"
            if ($m.Length -gt 300) { $m = $m.Substring(0, 300) }
            [pscustomobject]@{ time = $e.TimeCreated.ToUniversalTime().ToString('o'); id = [int]$e.Id; provider = "$($e.ProviderName)"; level = "$($e.LevelDisplayName)"; message = $m }
        }
    }
}
