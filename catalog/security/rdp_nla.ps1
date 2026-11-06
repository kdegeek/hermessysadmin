<# hermes-catalog
id: security.rdp_nla
title: Remote Desktop and NLA posture
category: Security posture
description: Whether Remote Desktop is enabled, whether Network Level Authentication is required and the listening port.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, rdp, nla, port]
tags: [rdp, nla, remote desktop, network level authentication, 3389]
source: In-box registry (Terminal Server and RDP-Tcp)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $deny = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server').fDenyTSConnections
        $tcp = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
        [pscustomobject]@{ rdp = ([int]$deny -eq 0); nla = ([int]$tcp.UserAuthentication -eq 1); port = $tcp.PortNumber }
    }
}
