<# hermes-catalog
id: patch.wu_health
title: Windows Update client health
category: Patching
description: Whether each computer's Windows Update client is working - the Windows Update and BITS service states, the last successful update search and install as recorded by the Windows Update Agent, days since the last install, whether updates were installed since the last boot (a restart is probably needed to finish them), the WSUS server from policy and the WSUS client ID. duplicate_client_id flags computers sharing a WSUS client ID (usually cloned images), which makes them overwrite each other in WSUS.
module: inbox:WindowsUpdateAgent
target: endpoint
tier: R
columns: [host, wuauserv, wuauserv_start, bits, last_search_success, last_install_success, days_since_install, last_boot, installed_since_boot, wsus_server, sus_client_id, duplicate_client_id]
tags: [windows update, wsus, wuauserv, bits, last scan, last install, susclientid, duplicate, reboot after update, patch compliance]
source: In-box Get-Service, CIM Win32_Service and Win32_OperatingSystem, registry (WindowsUpdate SusClientId and policy WUServer) and the Windows Update Agent COM API (Microsoft.Update.AutoUpdate Results, read only)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    $fan = Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $state = {
            param($n)
            $s = Get-Service -Name $n -ErrorAction SilentlyContinue
            if ($s) { "$($s.Status)" } else { 'NotInstalled' }
        }
        $wu = Get-CimInstance Win32_Service -Filter "Name='wuauserv'" -ErrorAction SilentlyContinue
        $os = Get-CimInstance Win32_OperatingSystem
        $boot = $null
        if ($os.LastBootUpTime) { $boot = ([datetime]$os.LastBootUpTime).ToUniversalTime() }
        $search = $null
        $install = $null
        try {
            $res = (New-Object -ComObject Microsoft.Update.AutoUpdate).Results
            if ($res.LastSearchSuccessDate -and ([datetime]$res.LastSearchSuccessDate).Year -gt 2000) { $search = [datetime]::SpecifyKind([datetime]$res.LastSearchSuccessDate, 'Utc') }
            if ($res.LastInstallationSuccessDate -and ([datetime]$res.LastInstallationSuccessDate).Year -gt 2000) { $install = [datetime]::SpecifyKind([datetime]$res.LastInstallationSuccessDate, 'Utc') }
        } catch { $search = $null; $install = $null }
        $policy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue
        $client = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate' -ErrorAction SilentlyContinue
        [pscustomobject]@{
            wuauserv = (& $state 'wuauserv')
            wuauserv_start = $(if ($wu) { "$($wu.StartMode)" } else { $null })
            bits = (& $state 'BITS')
            last_search_success = $(if ($search) { $search.ToString('o') } else { $null })
            last_install_success = $(if ($install) { $install.ToString('o') } else { $null })
            days_since_install = $(if ($install) { [math]::Floor(((Get-Date).ToUniversalTime() - $install).TotalDays) } else { $null })
            last_boot = $(if ($boot) { $boot.ToString('o') } else { $null })
            installed_since_boot = $(if ($install -and $boot) { $install -gt $boot } else { $null })
            wsus_server = $(if ($policy) { "$($policy.WUServer)" } else { $null })
            sus_client_id = $(if ($client -and $client.SusClientId) { "$($client.SusClientId)" } else { $null })
        }
    }
    $ids = @{}
    foreach ($r in $fan.items) { $i = "$($r['sus_client_id'])"; if ($i) { if ($ids.ContainsKey($i)) { $ids[$i]++ } else { $ids[$i] = 1 } } }
    foreach ($r in $fan.items) { $i = "$($r['sus_client_id'])"; $r['duplicate_client_id'] = ($i -ne '' -and $ids[$i] -gt 1) }
    $fan.summary['duplicate_client_ids'] = @($ids.Keys | Where-Object { $ids[$_] -gt 1 }).Count
    $fan.summary['no_install_30_days'] = @($fan.items | Where-Object { $null -ne $_['days_since_install'] -and $_['days_since_install'] -gt 30 }).Count
    $fan
}
