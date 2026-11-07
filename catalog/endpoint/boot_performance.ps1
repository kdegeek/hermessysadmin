<# hermes-catalog
id: endpoint.boot_performance
title: Boot time trend
category: Endpoint health
description: Recent boot durations from the Diagnostics-Performance log (event 100), newest first - total boot time, main path (to the desktop) and post-boot settling time in seconds. degraded is true when Windows flagged the boot as slow. Computers where the log is empty or disabled (common on Windows Server and some VMs) return no rows.
module: inbox:Microsoft.PowerShell.Diagnostics
target: endpoint
tier: R
columns: [host, time, boot_s, main_path_s, post_boot_s, degraded]
tags: [boot time, slow boot, startup time, slow startup, performance, logon slow]
source: In-box Get-WinEvent (Microsoft-Windows-Diagnostics-Performance/Operational event 100)
params:
  - {name: Max, type: integer, default: 10, minimum: 1, maximum: 50, description: Most boots to return per computer.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$Max = 10)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Max) -Script {
        param($max)
        $events = @()
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents $max -ErrorAction Stop)
        } catch {
            if ("$($_.FullyQualifiedErrorId)" -notmatch 'NoMatchingEventsFound|NoMatchingLogsFound') { throw }
        }
        foreach ($e in $events) {
            $d = @{}
            foreach ($n in @(([xml]$e.ToXml()).Event.EventData.Data)) { $d["$($n.Name)"] = "$($n.'#text')" }
            $sec = { param($k) if ($d.ContainsKey($k) -and $d[$k] -match '^\d+$') { [math]::Round([double]$d[$k] / 1000, 1) } else { $null } }
            [pscustomobject]@{ time = $e.TimeCreated.ToUniversalTime().ToString('o')
                               boot_s = & $sec 'BootTime'; main_path_s = & $sec 'MainPathBootTime'; post_boot_s = & $sec 'BootPostBootTime'
                               degraded = ($e.Level -ge 1 -and $e.Level -le 3) }
        }
    }
}
