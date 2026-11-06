<# hermes-catalog
id: endpoint.stopped_auto_services
title: Stopped automatic services
category: Endpoint health
description: Services set to start automatically that are not running, excluding delayed-start and trigger-start services that exited cleanly.
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, name, display, exit_code]
tags: [services, stopped, automatic, broken]
source: In-box CIM (Win32_Service)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        Get-CimInstance Win32_Service -Filter "StartMode='Auto'" | Where-Object { $_.State -ne 'Running' } | ForEach-Object {
            $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$($_.Name)"
            $delayed = [int]((Get-ItemProperty $key -Name DelayedAutostart -ErrorAction SilentlyContinue).DelayedAutostart) -eq 1
            $trigger = Test-Path (Join-Path $key 'TriggerInfo')
            if (-not (($delayed -or $trigger) -and [int64]$_.ExitCode -eq 0)) {
                [pscustomobject]@{ name = $_.Name; display = $_.DisplayName; exit_code = [int64]$_.ExitCode }
            }
        } | Select-Object -First 200
    }
}
