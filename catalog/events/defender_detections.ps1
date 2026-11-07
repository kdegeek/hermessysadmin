<# hermes-catalog
id: events.defender_detections
title: Microsoft Defender detections
category: Event logs
description: Malware detections and the action taken from the Microsoft Defender Antivirus operational log on each computer, newest first - detected (1116), action taken (1117), action failed (1118) and critical failure (1119) - with threat name, severity, file path (trimmed), affected user, process and action. Computers where Defender is not the antivirus return nothing.
module: inbox:Microsoft.PowerShell.Diagnostics
target: endpoint
tier: R
columns: [host, time, event, threat, severity, path, user, process, action]
tags: [defender, antivirus, malware, detection, threat, quarantine, 1116, 1117, virus]
source: In-box Get-WinEvent -FilterHashtable (Microsoft-Windows-Windows Defender/Operational 1116-1119)
params:
  - {name: Days, type: integer, default: 30, minimum: 1, maximum: 365, description: How many days back to look.}
  - {name: Max, type: integer, default: 50, minimum: 1, maximum: 500, description: Most events returned per computer.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$Days = 30, [int]$Max = 50)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Days, $Max) -Script {
        param($days, $max)
        $ErrorActionPreference = 'Stop'
        $names = @{ 1116 = 'detected'; 1117 = 'action taken'; 1118 = 'action failed'; 1119 = 'action critically failed' }
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = 1116, 1117, 1118, 1119; StartTime = (Get-Date).AddDays(-$days) } -MaxEvents $max)
        } catch {
            if ("$($_.FullyQualifiedErrorId)" -like 'NoMatching*') { return }
            throw
        }
        foreach ($e in $events) {
            $d = @{}
            foreach ($n in ([xml]$e.ToXml()).Event.EventData.Data) { $d["$($n.Name)"] = "$($n.'#text')" }
            $path = "$($d['Path'])"
            if ($path.Length -gt 300) { $path = $path.Substring(0, 300) }
            [pscustomobject]@{
                time = $e.TimeCreated.ToUniversalTime().ToString('o')
                event = $names[[int]$e.Id]
                threat = $d['Threat Name']
                severity = $d['Severity Name']
                path = $path
                user = $d['Detection User']
                process = $d['Process Name']
                action = $d['Action Name']
            }
        }
    }
}
