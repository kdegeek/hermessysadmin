<# hermes-catalog
id: network.traceroute
title: Trace the route to a host
category: Network
description: From each chosen computer, traces the network path to a host and lists every hop address in order. A hop of 0.0.0.0 did not answer (often a firewall dropping ICMP, not a fault). reached is true when the target itself answered. Hops are capped, and each computer has about a minute, so keep the hop count low for distant targets.
module: inbox:NetTCPIP
target: endpoint
tier: R
columns: [host, target, hop, address, reached]
tags: [traceroute, tracert, path, hops, route, latency, network path, test-netconnection]
source: In-box Test-NetConnection -TraceRoute
params:
  - {name: Target, type: string, required: true, description: Host name or IP address to trace to (letters, digits, dots and hyphens only).}
  - {name: Hops, type: integer, default: 15, minimum: 1, maximum: 20, description: Maximum number of hops to trace.}
#>
param([string[]]$Computers = @(), [string]$Ou, [string]$Target, [int]$Hops = 15)
Invoke-Op {
    if ($Target -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z') { throw 'InvalidArguments: Target must be a host name or IP address (letters, digits, dots and hyphens)' }
    if ($Hops -lt 1 -or $Hops -gt 20) { throw 'InvalidArguments: Hops must be between 1 and 20' }
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Target, $Hops) -Script {
        param($t, $h)
        $ErrorActionPreference = 'Stop'
        $r = Test-NetConnection -ComputerName $t -TraceRoute -Hops $h -WarningAction SilentlyContinue
        $reached = [bool]$r.PingSucceeded
        $i = 0
        foreach ($a in @($r.TraceRoute)) {
            $i++
            [pscustomobject]@{ target = $t; hop = $i; address = "$a"; reached = $reached }
        }
        if ($i -eq 0) { [pscustomobject]@{ target = $t; hop = 0; address = $null; reached = $reached } }
    }
}
