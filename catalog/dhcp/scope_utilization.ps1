<# hermes-catalog
id: dhcp.scope_utilization
title: DHCP scope utilization
category: DNS & DHCP
description: Address usage of every IPv4 DHCP scope on every DHCP server authorized in Active Directory. Each server reports on itself, so servers without the DHCP module or that cannot be reached appear under errors.
module: inbox:DhcpServer
target: dc
tier: R
columns: [server, scope, in_use, free, pct]
tags: [dhcp, scope, utilization, address pool, exhaustion, leases, free addresses]
source: In-box DhcpServer (Get-DhcpServerInDC, Get-DhcpServerv4ScopeStatistics), fanned out to each DHCP server
#>
param()
Invoke-Op {
    if (-not (Get-Command Get-DhcpServerInDC -ErrorAction SilentlyContinue)) { throw 'NotInstalled: DhcpServer module (RSAT) not present where Hermes runs PowerShell' }
    $servers = @(Get-DhcpServerInDC | ForEach-Object { "$($_.DnsName)" } | Where-Object { $_ })
    $fan = Invoke-HermesCatalogFanout -Computers $servers -Script {
        $ErrorActionPreference = 'Stop'
        foreach ($s in @(Get-DhcpServerv4ScopeStatistics)) {
            [pscustomobject]@{ server = $env:COMPUTERNAME; scope = "$($s.ScopeId)"; in_use = [int64]$s.InUse; free = [int64]$s.Free; pct = [math]::Round([double]$s.PercentageInUse, 1) }
        }
    }
    $rows = @($fan.items | Sort-Object { -[double]$_.pct })
    @{ items = @($rows | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); servers = $servers.Count; servers_ok = $fan.summary.ok; servers_failed = $fan.summary.failed } }
}
