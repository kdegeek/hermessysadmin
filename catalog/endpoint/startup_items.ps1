<# hermes-catalog
id: endpoint.startup_items
title: Startup items
category: Endpoint health
description: Programs that start at logon or boot from Run keys and startup folders.
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, name, command, location, user]
tags: [startup, autorun, boot, persistence]
source: In-box CIM (Win32_StartupCommand)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        Get-CimInstance Win32_StartupCommand | Select-Object -First 200 | ForEach-Object {
            [pscustomobject]@{ name = "$($_.Name)"; command = "$($_.Command)"; location = "$($_.Location)"; user = "$($_.User)" }
        }
    }
}
