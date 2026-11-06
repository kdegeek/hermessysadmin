<# hermes-catalog
id: endpoint.battery
title: Battery health
category: Endpoint health
description: Battery presence, charge level and wear (full-charge capacity versus design). present is false on desktops.
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, present, charge_pct, health_pct]
tags: [battery, laptop, power, wear]
source: In-box CIM (Win32_Battery, root\wmi BatteryFullChargedCapacity and BatteryStaticData)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $b = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
        if ($b.Count -eq 0) { return [pscustomobject]@{ present = $false; charge_pct = $null; health_pct = $null } }
        $health = $null
        try {
            $full = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity
            $design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity
            if ($design) { $health = [math]::Round(100 * $full / $design, 1) }
        } catch { $health = $null }
        [pscustomobject]@{ present = $true; charge_pct = $b[0].EstimatedChargeRemaining; health_pct = $health }
    }
}
