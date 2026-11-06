<# hermes-catalog
id: remote.enable_rdp
title: Enable or disable Remote Desktop
category: Remote access
description: Turns Remote Desktop on or off. Enabling also enables the Remote Desktop firewall rules.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: W
preview: plan
columns: [host, before, after]
tags: [rdp, remote desktop, remote access]
source: In-box registry (fDenyTSConnections) and NetSecurity firewall rules
params:
  - {name: Enabled, type: boolean, default: true, description: True to allow Remote Desktop connections and false to deny them.}
#>
param([string[]]$Computers = @(), [string]$Ou, [bool]$Enabled = $true, [switch]$Preview)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    $want = if ($Enabled) { 0 } else { 1 }
    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers $targets -Script {
            [pscustomobject]@{ before = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server').fDenyTSConnections }
        }
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = $r['before'] }
        return @{ summary = "Set Remote Desktop enabled=$Enabled on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { "$($_['host']): fDenyTSConnections $($_['before']) -> $want" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($want) -Script {
        param($v)
        $ErrorActionPreference = 'Stop'
        $k = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
        $before = (Get-ItemProperty $k).fDenyTSConnections
        Set-ItemProperty -Path $k -Name fDenyTSConnections -Value $v
        if ($v -eq 0) { Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' }
        [pscustomobject]@{ before = $before; after = (Get-ItemProperty $k).fDenyTSConnections }
    }
}
