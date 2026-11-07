<# hermes-catalog
id: events.powershell_suspicious
title: Suspicious PowerShell script blocks
category: Event logs
description: Script blocks that PowerShell itself flagged as suspicious and logged as warnings (PowerShell operational log 4104, level Warning) on each computer, newest first, grouped by script block - time, script path (empty for typed or remote commands), script block ID, parts logged, total length and the user SID. The script text is never returned; review it on the computer in Event Viewer. Logged even when script block logging is not configured.
module: inbox:Microsoft.PowerShell.Diagnostics
target: endpoint
tier: R
columns: [host, time, path, script_block_id, parts, length, user]
tags: [powershell, script block, 4104, suspicious, malicious powershell, obfuscation, amsi, script block logging]
source: In-box Get-WinEvent -FilterHashtable (Microsoft-Windows-PowerShell/Operational 4104, level 3)
params:
  - {name: Days, type: integer, default: 7, minimum: 1, maximum: 90, description: How many days back to look.}
  - {name: Max, type: integer, default: 50, minimum: 1, maximum: 200, description: Most script blocks returned per computer.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$Days = 7, [int]$Max = 50)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Days, $Max) -Script {
        param($days, $max)
        $ErrorActionPreference = 'Stop'
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-PowerShell/Operational'; Id = 4104; Level = 3; StartTime = (Get-Date).AddDays(-$days) } -MaxEvents 1000)
        } catch {
            if ("$($_.FullyQualifiedErrorId)" -like 'NoMatching*') { return }
            throw
        }
        $blocks = @{}
        $order = @()
        foreach ($e in $events) {
            $d = @{}
            foreach ($n in ([xml]$e.ToXml()).Event.EventData.Data) { $d["$($n.Name)"] = "$($n.'#text')" }
            $id = "$($d['ScriptBlockId'])"
            # Only the length of ScriptBlockText is kept; the text is dropped here.
            $len = "$($d['ScriptBlockText'])".Length
            $d.Remove('ScriptBlockText')
            if (-not $blocks.ContainsKey($id)) {
                $blocks[$id] = @{ time = $e.TimeCreated.ToUniversalTime().ToString('o'); path = "$($d['Path'])"; script_block_id = $id; parts = 0; length = 0; user = $(if ($e.UserId) { "$($e.UserId.Value)" } else { $null }) }
                $order += $id
            }
            $blocks[$id]['parts']++
            $blocks[$id]['length'] += $len
        }
        foreach ($id in @($order | Select-Object -First $max)) { [pscustomobject]$blocks[$id] }
    }
}
