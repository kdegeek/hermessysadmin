<# hermes-catalog
id: dhcp.lease_for_mac
title: DHCP lease for a MAC address
category: DNS & DHCP
description: Finds a MAC address in the IPv4 leases and reservations of every DHCP server authorized in AD and shows the IP, host name, lease state, expiry and whether it is reserved. Accepts aa-bb-cc-dd-ee-ff, aa:bb:cc:dd:ee:ff or aabbccddeeff.
module: inbox:DhcpServer
target: dc
tier: R
columns: [server, scope, ip, mac, hostname, state, expires, reserved]
tags: [dhcp, mac address, lease, find device, which ip, reservation, client id]
source: In-box DhcpServer (Get-DhcpServerInDC, Get-DhcpServerv4Lease, Get-DhcpServerv4Reservation), fanned out to each DHCP server
params:
  - {name: Mac, type: string, required: true, description: 'MAC address, for example 00-15-5d-01-02-03.'}
#>
param([string]$Mac)
Invoke-Op {
    if ($Mac -cnotmatch '\A[0-9A-Fa-f]{2}(?:[-:]?[0-9A-Fa-f]{2}){5}\z') { throw 'InvalidArguments: Mac must be a MAC address such as 00-15-5d-01-02-03, 00:15:5d:01:02:03 or 00155d010203' }
    if (-not (Get-Command Get-DhcpServerInDC -ErrorAction SilentlyContinue)) { throw 'NotInstalled: DhcpServer module (RSAT) not present where Hermes runs PowerShell' }
    $want = ($Mac -replace '[-:]', '').ToLowerInvariant()
    $servers = @(Get-DhcpServerInDC | ForEach-Object { "$($_.DnsName)" } | Where-Object { $_ })
    $fan = Invoke-HermesCatalogFanout -Computers $servers -ArgumentList @($want) -Script {
        param($m)
        $ErrorActionPreference = 'Stop'
        $seen = @{}
        foreach ($sc in @(Get-DhcpServerv4Scope)) {
            $res = @{}
            foreach ($r in @(Get-DhcpServerv4Reservation -ScopeId $sc.ScopeId)) {
                if (("$($r.ClientId)" -replace '[-:]', '').ToLowerInvariant() -eq $m) { $res["$($r.IPAddress)"] = $r }
            }
            foreach ($l in @(Get-DhcpServerv4Lease -ScopeId $sc.ScopeId)) {
                if (("$($l.ClientId)" -replace '[-:]', '').ToLowerInvariant() -ne $m) { continue }
                $ip = "$($l.IPAddress)"
                $seen[$ip] = $true
                $exp = $null
                if ($l.LeaseExpiryTime) { $exp = ([datetime]$l.LeaseExpiryTime).ToUniversalTime().ToString('o') }
                [pscustomobject]@{ server = $env:COMPUTERNAME; scope = "$($sc.ScopeId)"; ip = $ip; mac = "$($l.ClientId)"; hostname = "$($l.HostName)"; state = "$($l.AddressState)"; expires = $exp; reserved = $res.ContainsKey($ip) }
            }
            foreach ($ip in @($res.Keys)) {
                if ($seen.ContainsKey($ip)) { continue }
                $r = $res[$ip]
                [pscustomobject]@{ server = $env:COMPUTERNAME; scope = "$($sc.ScopeId)"; ip = $ip; mac = "$($r.ClientId)"; hostname = "$($r.Name)"; state = 'ReservedNoLease'; expires = $null; reserved = $true }
            }
        }
    }
    $rows = @($fan.items)
    @{ items = @($rows | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); servers = $servers.Count; servers_ok = $fan.summary.ok; servers_failed = $fan.summary.failed } }
}
