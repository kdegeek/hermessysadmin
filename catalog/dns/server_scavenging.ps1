<# hermes-catalog
id: dns.server_scavenging
title: DNS server scavenging settings
category: DNS & DHCP
description: Server-level scavenging on every domain controller running DNS - whether it scavenges, how often, when it last did, and the default refresh and no-refresh intervals for new zones. Zone aging alone removes nothing; at least one DNS server must scavenge. Intervals are in hours. Zone-level aging is in dns.zones.
module: inbox:DnsServer
target: dc
tier: R
columns: [host, scavenging, interval_h, last_scavenge, refresh_h, no_refresh_h]
tags: [dns, scavenging, aging, stale records, cleanup, last scavenge, refresh interval]
source: In-box DnsServer (Get-DnsServerScavenging) run locally on each DC through the fan-out
#>
param()
Invoke-Op {
    $dcs = @(Get-ADDomainController -Filter * | ForEach-Object { $_.HostName } | Where-Object { $_ })
    $fan = Invoke-HermesCatalogFanout -Computers $dcs -Script {
        $ErrorActionPreference = 'Stop'
        if (-not (Get-Command Get-DnsServerScavenging -ErrorAction SilentlyContinue)) { throw 'NotInstalled: the DNS Server role (DnsServer module) is not on this DC' }
        $s = Get-DnsServerScavenging
        $last = $null
        if ($s.LastScavengeTime -and ([datetime]$s.LastScavengeTime).Year -gt 1601) { $last = ([datetime]$s.LastScavengeTime).ToUniversalTime().ToString('o') }
        [pscustomobject]@{
            scavenging = (@('True', '1') -contains "$($s.ScavengingState)"); interval_h = [int]$s.ScavengingInterval.TotalHours; last_scavenge = $last
            refresh_h = [int]$s.RefreshInterval.TotalHours; no_refresh_h = [int]$s.NoRefreshInterval.TotalHours
        }
    }
    $rows = @($fan.items)
    $on = @($rows | Where-Object { $_['scavenging'] -and $_['interval_h'] -gt 0 }).Count
    @{ items = @($rows | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); scavenging_servers = $on; dcs = $dcs.Count; dcs_ok = $fan.summary.ok; dcs_failed = $fan.summary.failed } }
}
