<# hermes-catalog
id: dhcp.scopes
title: DHCP scopes and options
category: DNS & DHCP
description: Every IPv4 scope on every DHCP server authorized in Active Directory, with its state, address range, mask, lease duration and the router, DNS server and domain name options it hands out (scope value, or the server-wide value when the scope sets none). Look for inactive scopes, wrong DNS servers and very short or very long leases.
module: inbox:DhcpServer
target: dc
tier: R
columns: [server, scope, name, state, start, end, mask, lease_h, router, dns_servers, domain]
tags: [dhcp, scopes, options, router, gateway, dns servers, lease duration, option 6, option 3, option 15]
source: In-box DhcpServer (Get-DhcpServerInDC, Get-DhcpServerv4Scope, Get-DhcpServerv4OptionValue), fanned out to each DHCP server
#>
param()
Invoke-Op {
    if (-not (Get-Command Get-DhcpServerInDC -ErrorAction SilentlyContinue)) { throw 'NotInstalled: DhcpServer module (RSAT) not present where Hermes runs PowerShell' }
    $servers = @(Get-DhcpServerInDC | ForEach-Object { "$($_.DnsName)" } | Where-Object { $_ })
    $fan = Invoke-HermesCatalogFanout -Computers $servers -Script {
        $ErrorActionPreference = 'Stop'
        $serverOpts = @{}
        try { foreach ($o in @(Get-DhcpServerv4OptionValue)) { $serverOpts[[int]$o.OptionId] = (@($o.Value) -join ', ') } } catch { }
        foreach ($sc in @(Get-DhcpServerv4Scope | Sort-Object ScopeId | Select-Object -First 200)) {
            $opts = @{}
            foreach ($k in $serverOpts.Keys) { $opts[$k] = $serverOpts[$k] }
            try { foreach ($o in @(Get-DhcpServerv4OptionValue -ScopeId $sc.ScopeId)) { $opts[[int]$o.OptionId] = (@($o.Value) -join ', ') } } catch { }
            [pscustomobject]@{
                server = $env:COMPUTERNAME; scope = "$($sc.ScopeId)"; name = "$($sc.Name)"; state = "$($sc.State)"
                start = "$($sc.StartRange)"; end = "$($sc.EndRange)"; mask = "$($sc.SubnetMask)"
                lease_h = $(if ($sc.LeaseDuration) { [math]::Round(([timespan]$sc.LeaseDuration).TotalHours, 1) } else { $null })
                router = $opts[3]; dns_servers = $opts[6]; domain = $opts[15]
            }
        }
    }
    $rows = @($fan.items)
    @{ items = @($rows | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); servers = $servers.Count; servers_ok = $fan.summary.ok; servers_failed = $fan.summary.failed } }
}
