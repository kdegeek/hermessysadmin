<# hermes-catalog
id: network.register_dns
title: Re-register in DNS (ipconfig /registerdns)
category: Network
description: Asks each computer's DNS client to register its addresses again in DNS (A and PTR records), like ipconfig /registerdns. Use it after fixing a missing or wrong host record. Registration happens in the background, so check the record a minute later. Only interfaces set to register their address are affected; the preview lists them.
module: inbox:DnsClient
target: endpoint
tier: W
preview: plan
columns: [host, interfaces, addresses, before, after]
tags: [dns, register, registerdns, ipconfig, a record, ptr, dynamic update, host record]
source: In-box Get-DnsClient, Get-NetIPAddress and Register-DnsClient
#>
param([string[]]$Computers = @(), [string]$Ou, [switch]$Preview)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers $targets -Script {
            $ErrorActionPreference = 'Stop'
            $ifs = @(Get-DnsClient | Where-Object { $_.RegisterThisConnectionsAddress })
            $idx = @($ifs | ForEach-Object { [int]$_.InterfaceIndex })
            $addrs = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $idx -contains [int]$_.InterfaceIndex -and "$($_.IPAddress)" -notmatch '^(127\.|169\.254\.)' })
            [pscustomobject]@{ interfaces = (@($addrs | ForEach-Object { "$($_.InterfaceAlias)" } | Sort-Object -Unique) -join ', '); addresses = (@($addrs | ForEach-Object { "$($_.IPAddress)" }) -join ', ') }
        }
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = @{ interfaces = $r['interfaces']; addresses = $r['addresses'] } }
        return @{ summary = "Re-register DNS records on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { "$($_['host']): register $($_['addresses']) ($($_['interfaces']))" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $ifs = @(Get-DnsClient | Where-Object { $_.RegisterThisConnectionsAddress })
        $idx = @($ifs | ForEach-Object { [int]$_.InterfaceIndex })
        $addrs = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $idx -contains [int]$_.InterfaceIndex -and "$($_.IPAddress)" -notmatch '^(127\.|169\.254\.)' })
        Register-DnsClient
        [pscustomobject]@{
            interfaces = (@($addrs | ForEach-Object { "$($_.InterfaceAlias)" } | Sort-Object -Unique) -join ', '); addresses = (@($addrs | ForEach-Object { "$($_.IPAddress)" }) -join ', ')
            before = 'registration not requested'; after = 'registration requested'
        }
    }
}
