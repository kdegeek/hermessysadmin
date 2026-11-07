<# hermes-catalog
id: dns.clear_server_cache
title: Clear a DNS server's cache
category: DNS & DHCP
description: Clears the resolver cache of the DNS service on one domain controller, so names it learned from forwarders or other servers (including a stale or wrong answer) are looked up again. Zone data is not touched. Lookups are briefly slower while the cache refills. Server must be one of the domain's DCs; it defaults to the DC Hermes uses.
module: inbox:DnsServer
target: dc
tier: W
preview: plan
columns: [host, before, after]
tags: [dns, cache, clear cache, flush, dns server, stale answer, dnscmd clearcache]
source: In-box DnsServer (Get-DnsServerCache, Clear-DnsServerCache) run locally on the DC through the fan-out
params:
  - {name: Server, type: string, description: Host name of the domain controller whose DNS cache to clear. Defaults to the DC Hermes uses.}
#>
param([string]$Server, [switch]$Preview)
Invoke-Op {
    if ($Server -and $Server -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z') { throw 'InvalidArguments: Server must be a host name (letters, digits, dots and hyphens)' }
    $dcs = @(Get-ADDomainController -Filter * | ForEach-Object { "$($_.HostName)" } | Where-Object { $_ })
    $want = $Server
    if (-not $want) { $want = Get-HermesDc }
    $match = @($dcs | Where-Object { $_ -ieq $want -or ($_ -split '\.')[0] -ieq $want })
    if ($match.Count -ne 1) { throw "InvalidArguments: '$want' is not one of this domain's domain controllers ($($dcs -join ', '))" }
    $dc = $match[0]
    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers @($dc) -Script {
            $ErrorActionPreference = 'Stop'
            if (-not (Get-Command Get-DnsServerCache -ErrorAction SilentlyContinue)) { throw 'NotInstalled: the DNS Server role (DnsServer module) is not on this DC' }
            $c = Get-DnsServerCache
            [pscustomobject]@{ max_ttl_h = [int]$c.MaxTtl.TotalHours; locking_pct = [int]$c.LockingPercent; service = "$((Get-Service -Name DNS).Status)" }
        }
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = @{ max_ttl_h = $r['max_ttl_h']; locking_pct = $r['locking_pct']; service = $r['service'] } }
        return @{ summary = "Clear the DNS server cache on $dc"
                  changes = @($read.items | ForEach-Object { "$($_['host']): clear every cached DNS answer (DNS service $($_['service']); zone data is not changed)" }) + @($read.errors | ForEach-Object { "$($_.host): cannot clear ($($_.message))" })
                  current = $cur }
    }
    $fan = Invoke-HermesCatalogFanout -Computers @($dc) -Script {
        $ErrorActionPreference = 'Stop'
        if (-not (Get-Command Clear-DnsServerCache -ErrorAction SilentlyContinue)) { throw 'NotInstalled: the DNS Server role (DnsServer module) is not on this DC' }
        Clear-DnsServerCache -Force
        [pscustomobject]@{ before = 'cached answers present'; after = 'cache cleared' }
    }
    if ($fan.errors.Count -gt 0) { throw "$($fan.errors[0].host): $($fan.errors[0].message)" }
    $fan
}
