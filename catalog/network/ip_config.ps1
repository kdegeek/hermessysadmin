<# hermes-catalog
id: network.ip_config
title: IP configuration
category: Network
description: IPv4 address, default gateway, DNS servers and whether DHCP is on, per network interface that has an address.
module: inbox:NetTCPIP
target: endpoint
tier: R
columns: [host, interface, ipv4, gateway, dns, dhcp]
tags: [ip, address, gateway, dns, dhcp, nic, adapter, network]
source: In-box Get-NetIPConfiguration
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        foreach ($c in @(Get-NetIPConfiguration | Where-Object { $_.IPv4Address } | Select-Object -First 200)) {
            [pscustomobject]@{
                interface = "$($c.InterfaceAlias)"
                ipv4 = (@($c.IPv4Address | ForEach-Object { $_.IPAddress }) -join ', ')
                gateway = (@($c.IPv4DefaultGateway | ForEach-Object { $_.NextHop }) -join ', ')
                dns = (@($c.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses }) -join ', ')
                dhcp = ("$($c.NetIPv4Interface.Dhcp)" -eq 'Enabled')
            }
        }
    }
}
