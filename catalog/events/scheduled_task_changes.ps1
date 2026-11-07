<# hermes-catalog
id: events.scheduled_task_changes
title: Scheduled task changes
category: Event logs
description: Scheduled tasks created (Security 4698), deleted (4699), enabled (4700), disabled (4701) or updated (4702) on each computer, newest first, with who did it. The task definition itself is not returned. Needs "Audit Other Object Access Events" success auditing, which is off by default; computers without it return nothing. Unexpected new tasks are a common persistence method.
module: inbox:Microsoft.PowerShell.Diagnostics
target: endpoint
tier: R
columns: [host, time, action, task, by]
tags: [scheduled task, task created, 4698, 4702, persistence, task scheduler, security log]
source: In-box Get-WinEvent -FilterHashtable (Security 4698-4702)
params:
  - {name: Days, type: integer, default: 7, minimum: 1, maximum: 90, description: How many days back to look.}
  - {name: Max, type: integer, default: 100, minimum: 1, maximum: 500, description: Most events returned per computer.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$Days = 7, [int]$Max = 100)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Days, $Max) -Script {
        param($days, $max)
        $ErrorActionPreference = 'Stop'
        $names = @{ 4698 = 'created'; 4699 = 'deleted'; 4700 = 'enabled'; 4701 = 'disabled'; 4702 = 'updated' }
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4698, 4699, 4700, 4701, 4702; StartTime = (Get-Date).AddDays(-$days) } -MaxEvents $max)
        } catch {
            if ("$($_.FullyQualifiedErrorId)" -like 'NoMatchingEventsFound*') { return }
            throw
        }
        foreach ($e in $events) {
            $d = @{}
            foreach ($n in ([xml]$e.ToXml()).Event.EventData.Data) { if ($n.Name -ne 'TaskContent' -and $n.Name -ne 'TaskContentNew') { $d["$($n.Name)"] = "$($n.'#text')" } }
            [pscustomobject]@{ time = $e.TimeCreated.ToUniversalTime().ToString('o'); action = $names[[int]$e.Id]; task = $d['TaskName']; by = "$($d['SubjectDomainName'])\$($d['SubjectUserName'])" }
        }
    }
}
