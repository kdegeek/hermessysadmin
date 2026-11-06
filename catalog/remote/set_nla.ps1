<# hermes-catalog
id: remote.set_nla
title: Require Network Level Authentication
category: Remote access
description: Turns Network Level Authentication for Remote Desktop on (recommended) or off.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: W
preview: plan
columns: [host, before, after]
tags: [rdp, nla, remote desktop, security]
source: In-box registry (RDP-Tcp UserAuthentication)
params:
  - {name: Required, type: boolean, default: true, description: Require NLA.}
#>
param([string[]]$Computers = @(), [string]$Ou, [bool]$Required = $true, [switch]$Preview)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    $want = [int]$Required
    $read = Invoke-HermesCatalogFanout -Computers $targets -Script {
        [pscustomobject]@{ before = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp').UserAuthentication }
    }
    if ($Preview) {
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = $r['before'] }
        return @{ summary = "Set NLA required=$Required on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { "$($_['host']): UserAuthentication $($_['before']) -> $want" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($want) -Script {
        param($v)
        $ErrorActionPreference = 'Stop'
        $k = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
        $before = (Get-ItemProperty $k).UserAuthentication
        Set-ItemProperty -Path $k -Name UserAuthentication -Value $v
        [pscustomobject]@{ before = $before; after = (Get-ItemProperty $k).UserAuthentication }
    }
}
