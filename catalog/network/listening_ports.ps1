<# hermes-catalog
id: network.listening_ports
title: Listening TCP ports
category: Network
description: TCP ports in the Listen state with the owning process, to spot unexpected services.
module: inbox:NetTCPIP
target: endpoint
tier: R
columns: [host, port, address, process, pid]
tags: [ports, listening, netstat, tcp, services, open ports]
source: In-box Get-NetTCPConnection and Get-Process
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $names = @{}
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { $names[[int]$p.Id] = $p.ProcessName }
        foreach ($c in @(Get-NetTCPConnection -State Listen | Sort-Object LocalPort | Select-Object -First 200)) {
            $owner = [int]$c.OwningProcess
            [pscustomobject]@{ port = [int]$c.LocalPort; address = "$($c.LocalAddress)"; process = $(if ($names.ContainsKey($owner)) { $names[$owner] } else { $null }); pid = $owner }
        }
    }
}
