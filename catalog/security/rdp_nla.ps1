<# hermes-catalog
id: security.rdp_nla
title: Remote Desktop and NLA posture
category: Security posture
description: Whether Remote Desktop is enabled, whether Network Level Authentication is required and the listening port. Group Policy overrides win over local settings.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, rdp, nla, port, source]
tags: [rdp, nla, remote desktop, network level authentication, 3389]
source: In-box registry (Terminal Server, RDP-Tcp and the Terminal Services policy key)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $deny = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server').fDenyTSConnections
        $tcp = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
        $nla = $tcp.UserAuthentication
        $pol = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -ErrorAction SilentlyContinue
        $source = 'local'
        if ($pol) {
            if ($null -ne $pol.fDenyTSConnections) { $deny = $pol.fDenyTSConnections; $source = 'policy' }
            if ($null -ne $pol.UserAuthentication) { $nla = $pol.UserAuthentication; $source = 'policy' }
        }
        [pscustomobject]@{ rdp = ([int]$deny -eq 0); nla = ([int]$nla -eq 1); port = $tcp.PortNumber; source = $source }
    }
}
