<# hermes-catalog
id: maint.flush_dns
title: Flush DNS client cache
category: Maintenance
description: Clears the DNS resolver cache on each computer so stale name lookups are refreshed.
module: inbox:DnsClient
target: endpoint
tier: W
preview: plan
columns: [host, before, after]
tags: [dns, flush, cache, ipconfig]
source: In-box Clear-DnsClientCache
#>
param([string[]]$Computers = @(), [string]$Ou, [switch]$Preview)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    $read = Invoke-HermesCatalogFanout -Computers $targets -Script {
        [pscustomobject]@{ before = @(Get-DnsClientCache -ErrorAction SilentlyContinue).Count }
    }
    if ($Preview) {
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = $r['before'] }
        return @{ summary = "Flush the DNS cache on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { "$($_['host']): clear $($_['before']) cached DNS entries" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $before = @(Get-DnsClientCache -ErrorAction SilentlyContinue).Count
        Clear-DnsClientCache
        [pscustomobject]@{ before = $before; after = @(Get-DnsClientCache -ErrorAction SilentlyContinue).Count }
    }
}
