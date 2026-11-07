<# hermes-catalog
id: endpoint.unexpected_shutdowns
title: Unexpected shutdowns and bugchecks
category: Endpoint health
description: Dirty shutdowns and blue screens from the System log, newest first. kernel_power is event 41 (rebooted without a clean shutdown - power loss, hang or crash), unexpected_shutdown is event 6008 and bugcheck is event 1001 (the stop code and dump file). Computers with none in the window return no rows.
module: inbox:Microsoft.PowerShell.Diagnostics
target: endpoint
tier: R
columns: [host, time, kind, id, detail]
tags: [crash, bsod, blue screen, bugcheck, kernel-power, 41, 6008, 1001, unexpected shutdown, reboot, stop code]
source: In-box Get-WinEvent (System log events 41 Microsoft-Windows-Kernel-Power, 6008 EventLog, 1001 WER-SystemErrorReporting)
params:
  - {name: Days, type: integer, default: 30, minimum: 1, maximum: 365, description: How many days back to look.}
  - {name: Max, type: integer, default: 50, minimum: 1, maximum: 200, description: Most events to return per computer.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$Days = 30, [int]$Max = 50)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Days, $Max) -Script {
        param($days, $max)
        $events = @()
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41, 6008, 1001; StartTime = (Get-Date).AddDays(-$days) } -MaxEvents 500 -ErrorAction Stop)
        } catch {
            if ("$($_.FullyQualifiedErrorId)" -notmatch 'NoMatchingEventsFound') { throw }
        }
        $events | Where-Object {
            ($_.Id -eq 41 -and $_.ProviderName -eq 'Microsoft-Windows-Kernel-Power') -or
            ($_.Id -eq 6008 -and $_.ProviderName -eq 'EventLog') -or
            ($_.Id -eq 1001 -and $_.ProviderName -match 'WER-SystemErrorReporting|BugCheck')
        } | Sort-Object TimeCreated -Descending | Select-Object -First $max | ForEach-Object {
            $kind = switch ($_.Id) { 41 { 'kernel_power' } 6008 { 'unexpected_shutdown' } default { 'bugcheck' } }
            $m = "$($_.Message)" -replace '\s+', ' '
            if ($m.Length -gt 300) { $m = $m.Substring(0, 300) }
            [pscustomobject]@{ time = $_.TimeCreated.ToUniversalTime().ToString('o'); kind = $kind; id = $_.Id; detail = $m }
        }
    }
}
