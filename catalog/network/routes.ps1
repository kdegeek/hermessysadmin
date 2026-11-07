<# hermes-catalog
id: network.routes
title: Routing table
category: Network
description: IPv4 and IPv6 routes on each computer with next hop, interface, route metric and whether the route is persistent (stored) or active only. Loopback, multicast and link-local host routes are left out. Up to 200 routes per computer.
module: inbox:NetTCPIP
target: endpoint
tier: R
columns: [host, destination, next_hop, interface, metric, family, store]
tags: [route, routing table, route print, gateway, next hop, static route, network]
source: In-box Get-NetRoute
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $skip = '^(127\.|224\.0\.0\.0/4|255\.255\.255\.255/32|::1/128|ff00::/8|fe80::)'
        $routes = @(Get-NetRoute | Where-Object { "$($_.DestinationPrefix)" -notmatch $skip } | Sort-Object AddressFamily, DestinationPrefix | Select-Object -First 200)
        foreach ($r in $routes) {
            [pscustomobject]@{
                destination = "$($r.DestinationPrefix)"; next_hop = "$($r.NextHop)"; interface = "$($r.InterfaceAlias)"
                metric = [int]$r.RouteMetric; family = "$($r.AddressFamily)"; store = "$($r.Store)"
            }
        }
    }
}
