<# hermes-catalog
id: network.dns_client
title: DNS client servers
category: Network
description: The IPv4 DNS servers each network interface is configured to use.
module: inbox:DnsClient
target: endpoint
tier: R
columns: [host, interface, servers]
tags: [dns, resolver, nameserver, client, servers]
source: In-box Get-DnsClientServerAddress
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        foreach ($d in @(Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { @($_.ServerAddresses).Count -gt 0 } | Select-Object -First 200)) {
            [pscustomobject]@{ interface = "$($d.InterfaceAlias)"; servers = (@($d.ServerAddresses) -join ', ') }
        }
    }
}
