<# hermes-catalog
id: dhcp.leases_for_host
title: DHCP leases for a host
category: DNS & DHCP
description: Searches the IPv4 leases on every authorized DHCP server for a hostname (substring match) and shows the IP, MAC and expiry. Each server searches itself.
module: inbox:DhcpServer
target: dc
tier: R
columns: [server, scope, ip, mac, hostname, expires]
tags: [dhcp, lease, leases, ip address, mac address, find host, who has ip, reservation]
source: In-box DhcpServer (Get-DhcpServerInDC, Get-DhcpServerv4Lease), fanned out to each DHCP server
params:
  - {name: Name, type: string, required: true, description: Hostname or part of a hostname to search for.}
#>
param([string]$Name)
Invoke-Op {
    if ($Name -notmatch '^[A-Za-z0-9.-]{1,64}$') { throw 'Name must be a hostname fragment (letters, digits, dots and hyphens, at most 64 characters)' }
    if (-not (Get-Command Get-DhcpServerInDC -ErrorAction SilentlyContinue)) { throw 'NotInstalled: DhcpServer module (RSAT) not present where Hermes runs PowerShell' }
    $servers = @(Get-DhcpServerInDC | ForEach-Object { "$($_.DnsName)" } | Where-Object { $_ })
    $fan = Invoke-HermesCatalogFanout -Computers $servers -ArgumentList @($Name) -Script {
        param($Name)
        $ErrorActionPreference = 'Stop'
        $out = @()
        foreach ($sc in @(Get-DhcpServerv4Scope)) {
            foreach ($l in @(Get-DhcpServerv4Lease -ScopeId $sc.ScopeId | Where-Object { "$($_.HostName)" -like "*$Name*" })) {
                $exp = $null
                if ($l.LeaseExpiryTime) { $exp = ([datetime]$l.LeaseExpiryTime).ToUniversalTime().ToString('o') }
                $out += [pscustomobject]@{ server = $env:COMPUTERNAME; scope = "$($sc.ScopeId)"; ip = "$($l.IPAddress)"; mac = "$($l.ClientId)"; hostname = "$($l.HostName)"; expires = $exp }
            }
        }
        $out | Select-Object -First 500
    }
    $rows = @($fan.items)
    @{ items = @($rows | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); servers = $servers.Count; servers_ok = $fan.summary.ok; servers_failed = $fan.summary.failed } }
}
