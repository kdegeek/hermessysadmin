<# hermes-catalog
id: patch.wu_config
title: Windows Update policy
category: Patching
description: Windows Update policy settings from the registry, including the WSUS server and automatic update options.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, wsus_server, use_wsus, au_options, no_auto_update, target_group]
tags: [wsus, windows update, policy, automatic updates, update server, patching]
source: In-box registry (Policies WindowsUpdate and AU)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Continue'
        $wu = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue
        $au = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction SilentlyContinue
        $opts = @{ 2 = 'Notify before download'; 3 = 'Auto download, notify to install'; 4 = 'Auto download and schedule install'; 5 = 'Local admin chooses'; 7 = 'Auto download, notify to install and restart' }
        $ao = $null
        if ($au -and $null -ne $au.AUOptions) { $n = [int]$au.AUOptions; $ao = $(if ($opts.ContainsKey($n)) { "$n - $($opts[$n])" } else { "$n" }) }
        [pscustomobject]@{
            wsus_server = $(if ($wu) { $wu.WUServer } else { $null })
            use_wsus = $(if ($au -and $null -ne $au.UseWUServer) { [int]$au.UseWUServer -eq 1 } else { $false })
            au_options = $ao
            no_auto_update = $(if ($au -and $null -ne $au.NoAutoUpdate) { [int]$au.NoAutoUpdate -eq 1 } else { $false })
            target_group = $(if ($wu) { $wu.TargetGroup } else { $null })
        }
    }
}
