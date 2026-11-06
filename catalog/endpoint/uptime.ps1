<# hermes-catalog
id: endpoint.uptime
title: Uptime and last boot
category: Endpoint health
description: Last boot time and uptime per computer; flags machines up longer than MaxDays.
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, last_boot, uptime_days, long_uptime]
tags: [uptime, reboot, boot]
source: In-box CIM (Win32_OperatingSystem)
params:
  - {name: MaxDays, type: integer, default: 30, minimum: 1, description: Flag machines up longer than this many days.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$MaxDays = 30)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($MaxDays) -Script {
        param($max)
        $os = Get-CimInstance Win32_OperatingSystem
        $up = (Get-Date) - $os.LastBootUpTime
        [pscustomobject]@{ last_boot = $os.LastBootUpTime.ToUniversalTime().ToString('o'); uptime_days = [math]::Round($up.TotalDays, 1); long_uptime = ($up.TotalDays -gt $max) }
    }
}
