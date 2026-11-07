<# hermes-catalog
id: network.test_port
title: Test TCP connection to host:port
category: Network
description: From each computer, tests whether a TCP connection to Target on Port succeeds. ping_ms is the ICMP round trip and is empty when ping is blocked. Use it to check firewall rules and service reachability from the endpoint's point of view.
module: inbox:NetTCPIP
target: endpoint
tier: R
columns: [host, target, port, tcp_ok, ping_ms]
tags: [test, connection, port, tcp, reachability, firewall, telnet, tnc]
source: In-box Test-NetConnection
params:
  - {name: Target, type: string, required: true, description: Host name or IP address to connect to (letters, digits, dots and hyphens only).}
  - {name: Port, type: integer, required: true, minimum: 1, maximum: 65535, description: TCP port to test.}
#>
param([string[]]$Computers = @(), [string]$Ou, [string]$Target, [int]$Port)
Invoke-Op {
    if ($Target -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z') { throw 'InvalidArguments: Target must be a host name or IP address (letters, digits, dots and hyphens)' }
    if ($Port -lt 1 -or $Port -gt 65535) { throw 'InvalidArguments: Port must be between 1 and 65535' }
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Target, $Port) -Script {
        param($t, $p)
        $ErrorActionPreference = 'Stop'
        $r = Test-NetConnection -ComputerName $t -Port $p -WarningAction SilentlyContinue
        $ms = $null
        if ($r.PingSucceeded -and $r.PingReplyDetails) { $ms = [int]$r.PingReplyDetails.RoundtripTime }
        [pscustomobject]@{ target = $t; port = $p; tcp_ok = [bool]$r.TcpTestSucceeded; ping_ms = $ms }
    }
}
