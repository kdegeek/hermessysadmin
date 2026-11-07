<# hermes-catalog
id: dns.forwarders
title: DNS forwarders and conditional forwarders
category: DNS & DHCP
description: On every domain controller, the DNS server forwarders (with whether root hints are used when they fail and the root hint count) and each conditional forwarder zone with its master servers and whether it is stored in AD. Forwarders are per server, so differences between DCs show up here. DCs without the DNS Server role appear under errors.
module: inbox:DnsServer
target: dc
tier: R
columns: [host, kind, zone, servers, use_root_hints, root_hints, timeout_s, ds_integrated, replication_scope]
tags: [dns, forwarders, conditional forwarder, root hints, recursion, upstream dns, resolver]
source: In-box DnsServer (Get-DnsServerForwarder, Get-DnsServerZone, Get-DnsServerRootHint) run locally on each DC through the fan-out
#>
param()
Invoke-Op {
    $dcs = @(Get-ADDomainController -Filter * | ForEach-Object { $_.HostName } | Where-Object { $_ })
    $fan = Invoke-HermesCatalogFanout -Computers $dcs -Script {
        $ErrorActionPreference = 'Stop'
        if (-not (Get-Command Get-DnsServerForwarder -ErrorAction SilentlyContinue)) { throw 'NotInstalled: the DNS Server role (DnsServer module) is not on this DC' }
        $f = Get-DnsServerForwarder
        $hints = $null
        try { $hints = @(Get-DnsServerRootHint).Count } catch { $hints = $null }
        [pscustomobject]@{
            kind = 'forwarder'; zone = '.'; servers = (@($f.IPAddress | ForEach-Object { "$_" }) -join ', '); use_root_hints = [bool]$f.UseRootHint
            root_hints = $hints; timeout_s = [int]$f.Timeout; ds_integrated = $null; replication_scope = $null
        }
        foreach ($z in @(Get-DnsServerZone | Where-Object { "$($_.ZoneType)" -eq 'Forwarder' } | Sort-Object ZoneName | Select-Object -First 200)) {
            [pscustomobject]@{
                kind = 'conditional'; zone = "$($z.ZoneName)"; servers = (@($z.MasterServers | ForEach-Object { "$_" }) -join ', '); use_root_hints = $null
                root_hints = $null; timeout_s = $(if ($null -ne $z.ForwarderTimeout) { [int]$z.ForwarderTimeout } else { $null })
                ds_integrated = [bool]$z.IsDsIntegrated; replication_scope = "$($z.ReplicationScope)"
            }
        }
    }
    $rows = @($fan.items)
    @{ items = @($rows | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); dcs = $dcs.Count; dcs_ok = $fan.summary.ok; dcs_failed = $fan.summary.failed } }
}
