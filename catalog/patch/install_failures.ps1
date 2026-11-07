<# hermes-catalog
id: patch.install_failures
title: Windows Update installation failures
category: Patching
description: Updates that failed to install on each computer (System log, WindowsUpdateClient event 20), newest first, with the update title, KB and error code. Repeated failures of the same KB usually need the error code looked up, a component store repair or a manual install.
module: inbox:Microsoft.PowerShell.Diagnostics
target: endpoint
tier: R
columns: [host, time, kb, update, error_code]
tags: [windows update, failed update, installation failure, event 20, error code, 0x800f0922, patch failed, kb]
source: In-box Get-WinEvent -FilterHashtable (System, Microsoft-Windows-WindowsUpdateClient 20)
params:
  - {name: Days, type: integer, default: 30, minimum: 1, maximum: 365, description: How many days back to look.}
  - {name: Max, type: integer, default: 50, minimum: 1, maximum: 200, description: Most events returned per computer.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$Days = 30, [int]$Max = 50)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Days, $Max) -Script {
        param($days, $max)
        $ErrorActionPreference = 'Stop'
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 20; StartTime = (Get-Date).AddDays(-$days) } -MaxEvents $max)
        } catch {
            if ("$($_.FullyQualifiedErrorId)" -like 'NoMatchingEventsFound*') { return }
            throw
        }
        foreach ($e in $events) {
            $d = @{}
            foreach ($n in ([xml]$e.ToXml()).Event.EventData.Data) { $d["$($n.Name)"] = "$($n.'#text')" }
            $title = "$($d['updateTitle'])"
            if (-not $title) { $title = ("$($e.Message)" -replace '\s+', ' ') }
            if ($title.Length -gt 300) { $title = $title.Substring(0, 300) }
            $kb = $null
            if ($title -match '(KB\d{6,8})') { $kb = $Matches[1] }
            [pscustomobject]@{ time = $e.TimeCreated.ToUniversalTime().ToString('o'); kb = $kb; update = $title; error_code = "$($d['errorCode'])" }
        }
    }
}
