<# hermes-catalog
id: dhcp.reservations
title: DHCP reservations
category: DNS & DHCP
description: IPv4 reservations on every DHCP server authorized in Active Directory, with the scope, reserved IP, MAC (client ID), name and description. Contains filters to reservations whose name, IP, MAC or description contains that text.
module: inbox:DhcpServer
target: dc
tier: R
columns: [server, scope, ip, mac, name, description, type]
tags: [dhcp, reservation, reservations, static ip, mac address, fixed ip, printer ip]
source: In-box DhcpServer (Get-DhcpServerInDC, Get-DhcpServerv4Scope, Get-DhcpServerv4Reservation), fanned out to each DHCP server
params:
  - {name: Contains, type: string, description: Only reservations whose name, IP, MAC or description contains this text (letters, digits, spaces and . - _ :).}
#>
param([string]$Contains)
Invoke-Op {
    if ($Contains -and $Contains -cnotmatch '\A[A-Za-z0-9 ._:-]{1,64}\z') { throw 'InvalidArguments: Contains must be 1-64 letters, digits, spaces or . - _ :' }
    if (-not (Get-Command Get-DhcpServerInDC -ErrorAction SilentlyContinue)) { throw 'NotInstalled: DhcpServer module (RSAT) not present where Hermes runs PowerShell' }
    $servers = @(Get-DhcpServerInDC | ForEach-Object { "$($_.DnsName)" } | Where-Object { $_ })
    $fan = Invoke-HermesCatalogFanout -Computers $servers -ArgumentList @("$Contains") -Script {
        param($filter)
        $ErrorActionPreference = 'Stop'
        $out = @()
        foreach ($sc in @(Get-DhcpServerv4Scope)) {
            foreach ($r in @(Get-DhcpServerv4Reservation -ScopeId $sc.ScopeId)) {
                $text = "$($r.Name)|$($r.IPAddress)|$($r.ClientId)|$($r.Description)"
                if ($filter -and $text.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
                $out += [pscustomobject]@{ server = $env:COMPUTERNAME; scope = "$($sc.ScopeId)"; ip = "$($r.IPAddress)"; mac = "$($r.ClientId)"; name = "$($r.Name)"; description = "$($r.Description)"; type = "$($r.Type)" }
                if ($out.Count -ge 500) { break }
            }
            if ($out.Count -ge 500) { break }
        }
        $out
    }
    $rows = @($fan.items)
    @{ items = @($rows | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); servers = $servers.Count; servers_ok = $fan.summary.ok; servers_failed = $fan.summary.failed } }
}
