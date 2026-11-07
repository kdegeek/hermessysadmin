<# hermes-catalog
id: network.arp_cache
title: ARP and neighbour cache
category: Network
description: IPv4 ARP and IPv6 neighbour cache entries (IP to MAC) on each computer, with the interface and entry state. Multicast, broadcast and unreachable entries are left out. Up to 200 entries per computer. Useful for spotting duplicate IPs or a gateway MAC that changed.
module: inbox:NetTCPIP
target: endpoint
tier: R
columns: [host, ip, mac, interface, state]
tags: [arp, arp -a, neighbour, neighbor, mac address, ip conflict, duplicate ip, cache]
source: In-box Get-NetNeighbor
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $entries = @(Get-NetNeighbor | Where-Object {
            "$($_.State)" -ne 'Unreachable' -and "$($_.LinkLayerAddress)" -notmatch '^(00-00-00-00-00-00|FF-FF-FF-FF-FF-FF|01-00-5E|33-33)' -and "$($_.LinkLayerAddress)" -ne ''
        } | Sort-Object InterfaceAlias, IPAddress | Select-Object -First 200)
        foreach ($n in $entries) {
            [pscustomobject]@{ ip = "$($n.IPAddress)"; mac = "$($n.LinkLayerAddress)"; interface = "$($n.InterfaceAlias)"; state = "$($n.State)" }
        }
    }
}
