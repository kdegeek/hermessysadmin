<# hermes-catalog
id: dns.zone_security
title: DNS zone transfer and dynamic update settings
category: DNS & DHCP
description: For every primary and secondary zone on the domain controller's DNS server, the dynamic update mode (None, Secure, NonsecureAndSecure), who may request zone transfers, the allowed secondary servers and notify settings. risky is true when a zone accepts nonsecure dynamic updates or allows transfers to any server.
module: inbox:DnsServer
target: dc
tier: R
columns: [zone, type, dynamic_update, transfers, secondary_servers, notify, replication_scope, risky]
tags: [dns, zone transfer, axfr, dynamic update, nonsecure, secure updates, secondaries, notify, hardening]
source: In-box DnsServer (Get-DnsServerZone)
#>
param()
Invoke-Op {
    if (-not (Get-Command Get-DnsServerZone -ErrorAction SilentlyContinue)) { throw 'NotInstalled: DnsServer module (RSAT) not present where Hermes runs PowerShell' }
    $dns = Get-HermesDcTarget
    $rows = @()
    foreach ($z in @(Get-DnsServerZone @dns | Where-Object { -not $_.IsAutoCreated -and @('Primary', 'Secondary') -contains "$($_.ZoneType)" } | Sort-Object ZoneName)) {
        $upd = "$($z.DynamicUpdate)"
        $xfr = "$($z.SecureSecondaries)"
        $rows += @{
            zone = "$($z.ZoneName)"; type = "$($z.ZoneType)"; dynamic_update = $upd; transfers = $xfr
            secondary_servers = (@($z.SecondaryServers | ForEach-Object { "$_" }) -join ', '); notify = "$($z.Notify)"
            replication_scope = "$($z.ReplicationScope)"
            risky = ($upd -eq 'NonsecureAndSecure' -or $xfr -eq 'TransferAnyServer')
        }
    }
    @{ items = @($rows | Select-Object -First 500); errors = @(); summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); risky = @($rows | Where-Object { $_.risky }).Count; dns_server = (Get-HermesDc) } }
}
