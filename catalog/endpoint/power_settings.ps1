<# hermes-catalog
id: endpoint.power_settings
title: Power plan and sleep settings
category: Endpoint health
description: The active power plan and its sleep, hibernate and display-off timeouts in minutes on mains (ac) and battery (dc) power, where 0 means never, plus whether hibernation is enabled. Timeouts are blank when the power WMI namespace is unavailable.
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, plan, sleep_ac_min, sleep_dc_min, hibernate_ac_min, hibernate_dc_min, display_ac_min, display_dc_min, hibernate_enabled]
tags: [power, power plan, sleep, hibernate, standby, display timeout, powercfg, energy]
source: In-box CIM (root\cimv2\power Win32_PowerPlan and Win32_PowerSettingDataIndex) and the HKLM\SYSTEM\CurrentControlSet\Control\Power registry key
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $row = [ordered]@{ plan = ''; sleep_ac_min = $null; sleep_dc_min = $null; hibernate_ac_min = $null; hibernate_dc_min = $null
                           display_ac_min = $null; display_dc_min = $null; hibernate_enabled = $null }
        $pw = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue
        if ($pw -and $null -ne $pw.HibernateEnabled) { $row.hibernate_enabled = ([int]$pw.HibernateEnabled -ne 0) }
        try {
            $plan = Get-CimInstance -Namespace root\cimv2\power -ClassName Win32_PowerPlan -Filter 'IsActive = TRUE' -ErrorAction Stop | Select-Object -First 1
            if ($plan) {
                $row.plan = "$($plan.ElementName)"
                $guid = "$($plan.InstanceID)" -replace '^.*(\{[0-9A-Fa-f-]+\})$', '$1'
                $idx = @(Get-CimInstance -Namespace root\cimv2\power -ClassName Win32_PowerSettingDataIndex -ErrorAction Stop | Where-Object { "$($_.InstanceID)" -like "*$guid*" })
                $settings = @{ sleep = '{29f6c1db-86da-48c5-9fdb-f2b67b1f44da}'; hibernate = '{9d7815a6-7ee4-497e-8888-515a05f02364}'; display = '{3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e}' }
                foreach ($k in @($settings.Keys)) {
                    foreach ($src in 'AC', 'DC') {
                        $hit = $idx | Where-Object { "$($_.InstanceID)" -like "*\$src\$($settings[$k])" } | Select-Object -First 1
                        if ($hit) { $row["$($k)_$($src.ToLowerInvariant())_min"] = [math]::Round([double]$hit.SettingIndexValue / 60, 1) }
                    }
                }
            }
        } catch { }
        [pscustomobject]$row
    }
}
