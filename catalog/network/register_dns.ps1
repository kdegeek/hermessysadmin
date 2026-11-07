<# hermes-catalog
id: network.register_dns
title: Re-register in DNS (ipconfig /registerdns)
category: Network
description: Asks each computer's DNS client to register its addresses again in DNS (A and PTR records), like ipconfig /registerdns. Use it after fixing a missing or wrong host record. Registration happens in the background. before and after are the computer's own A records as its first DNS server answers them just before the request and about 5 seconds after it, so after can still show the old answer; check again a minute later. Only interfaces set to register their address are affected; the preview lists them.
module: inbox:DnsClient
target: endpoint
tier: W
preview: plan
columns: [host, interfaces, addresses, before, after]
tags: [dns, register, registerdns, ipconfig, a record, ptr, dynamic update, host record]
source: In-box Get-DnsClient, Get-DnsClientServerAddress, Get-NetIPAddress, Resolve-DnsName and Register-DnsClient
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
        # The computer's own A records as its first DNS server answers them (asked directly, not from the cache).
        $cs = Get-CimInstance Win32_ComputerSystem
        $fqdn = "$($cs.DNSHostName).$($cs.Domain)"
        $dnsSrv = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $idx -contains [int]$_.InterfaceIndex } | ForEach-Object { $_.ServerAddresses } | Where-Object { $_ }) | Select-Object -First 1
        function Get-OwnA {
            if (-not $dnsSrv) { return 'unknown (no DNS server configured)' }
            try {
                $a = @(Resolve-DnsName -Name $fqdn -Type A -Server $dnsSrv -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object { "$($_.Type)" -eq 'A' } | ForEach-Object { "$($_.IPAddress)" } | Sort-Object -Unique)
                if ($a.Count -eq 0) { return "$fqdn has no A record on $dnsSrv" }
                return "$fqdn -> $($a -join ', ') on $dnsSrv"
            } catch { return "$fqdn not resolved on $dnsSrv ($($_.Exception.Message))" }
        }
        $before = Get-OwnA
        Register-DnsClient
        Start-Sleep -Seconds 5
        [pscustomobject]@{
            interfaces = (@($addrs | ForEach-Object { "$($_.InterfaceAlias)" } | Sort-Object -Unique) -join ', '); addresses = (@($addrs | ForEach-Object { "$($_.IPAddress)" }) -join ', ')
            before = $before; after = (Get-OwnA)
        }
    }
}
