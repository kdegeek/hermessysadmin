<# hermes-catalog
id: printers.events
title: Print service errors
category: Printers
description: Errors and warnings from the PrintService Admin event log on each computer (driver load failures, spooler crashes, failed printer connections and installs), newest first, with the message trimmed to 300 characters. Defaults to every enabled server when no computers are given.
module: inbox:Microsoft.PowerShell.Diagnostics
target: endpoint
tier: R
columns: [host, time, id, level, message]
tags: [printers, print service, event log, spooler crash, driver error, print server, printservice admin]
source: In-box Get-WinEvent -FilterHashtable (Microsoft-Windows-PrintService/Admin)
params:
  - {name: Hours, type: integer, default: 72, minimum: 1, maximum: 720, description: How many hours back to look.}
  - {name: Max, type: integer, default: 50, minimum: 1, maximum: 200, description: Maximum events returned per computer.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$Hours = 72, [int]$Max = 50)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Server
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Hours, $Max) -Script {
        param($h, $max)
        $ErrorActionPreference = 'Stop'
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-PrintService/Admin'; Level = @(1, 2, 3); StartTime = (Get-Date).AddHours(-$h) } -MaxEvents $max)
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
}
