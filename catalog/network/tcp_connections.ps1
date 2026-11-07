<# hermes-catalog
id: network.tcp_connections
title: Established TCP connections
category: Network
description: TCP connections in the Established state with local and remote endpoints and the owning process, loopback connections excluded. Optionally filtered to one remote port. Up to 200 connections per computer.
module: inbox:NetTCPIP
target: endpoint
tier: R
columns: [host, local, remote, remote_port, process, pid]
tags: [tcp, connections, netstat, established, remote address, process, network, sessions]
source: In-box Get-NetTCPConnection and Get-Process
params:
  - {name: RemotePort, type: integer, default: 0, minimum: 0, maximum: 65535, description: Only connections to this remote port. 0 means every port.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$RemotePort = 0)
Invoke-Op {
    if ($RemotePort -lt 0 -or $RemotePort -gt 65535) { throw 'InvalidArguments: RemotePort must be between 0 and 65535' }
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($RemotePort) -Script {
        param($rp)
        $ErrorActionPreference = 'Stop'
        $names = @{}
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { $names[[int]$p.Id] = $p.ProcessName }
        $conns = @()
        try { $conns = @(Get-NetTCPConnection -State Established) } catch { if ("$($_.CategoryInfo.Category)" -eq 'ObjectNotFound') { $conns = @() } else { throw } }
        $conns = @($conns | Where-Object { "$($_.RemoteAddress)" -notmatch '^(127\.|::1$|::ffff:127\.)' -and ($rp -eq 0 -or [int]$_.RemotePort -eq $rp) } |
            Sort-Object RemoteAddress, RemotePort | Select-Object -First 200)
        foreach ($c in $conns) {
            $owner = [int]$c.OwningProcess
            [pscustomobject]@{
                local = "$($c.LocalAddress):$($c.LocalPort)"; remote = "$($c.RemoteAddress)"; remote_port = [int]$c.RemotePort
                process = $(if ($names.ContainsKey($owner)) { $names[$owner] } else { $null }); pid = $owner
            }
        }
    }
}
