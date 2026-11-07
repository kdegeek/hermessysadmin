<# hermes-catalog
id: network.profiles
title: Network profile (Public, Private, Domain)
category: Network
description: The network category of each connected network (Public, Private or DomainAuthenticated) and its IPv4 connectivity. not_domain is true when a domain-joined computer has a connection that is not DomainAuthenticated; that usually means it could not reach a DC when the network was identified, and the stricter Public or Private firewall profile is applying.
module: inbox:NetConnection
target: endpoint
tier: R
columns: [host, interface, network, category, ipv4, domain_joined, not_domain]
tags: [network profile, network category, public, private, domain, nla, firewall profile, ncsi]
source: In-box Get-NetConnectionProfile and Win32_ComputerSystem
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $joined = [bool](Get-CimInstance Win32_ComputerSystem).PartOfDomain
        foreach ($p in @(Get-NetConnectionProfile | Sort-Object InterfaceAlias | Select-Object -First 50)) {
            $cat = "$($p.NetworkCategory)"
            [pscustomobject]@{
                interface = "$($p.InterfaceAlias)"; network = "$($p.Name)"; category = $cat; ipv4 = "$($p.IPv4Connectivity)"
                domain_joined = $joined; not_domain = ($joined -and $cat -ne 'DomainAuthenticated')
            }
        }
    }
}
