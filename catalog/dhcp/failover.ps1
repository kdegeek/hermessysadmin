<# hermes-catalog
id: dhcp.failover
title: DHCP failover relationships
category: DNS & DHCP
description: IPv4 failover relationships as each DHCP server authorized in AD sees them - partner, mode (LoadBalance or HotStandby), state, this server's role, the scopes covered, maximum client lead time and load or reserve percentage. Each partner reports its own row, so a relationship in Normal on one side and CommunicationInterrupted or PartnerDown on the other stands out. The shared secret is never read.
module: inbox:DhcpServer
target: dc
tier: R
columns: [server, relationship, partner, mode, state, role, scopes, mclt_min, load_pct, reserve_pct]
tags: [dhcp, failover, partner, load balance, hot standby, redundancy, partnerdown, communication interrupted]
source: In-box DhcpServer (Get-DhcpServerInDC, Get-DhcpServerv4Failover), fanned out to each DHCP server
#>
param()
Invoke-Op {
    if (-not (Get-Command Get-DhcpServerInDC -ErrorAction SilentlyContinue)) { throw 'NotInstalled: DhcpServer module (RSAT) not present where Hermes runs PowerShell' }
    $servers = @(Get-DhcpServerInDC | ForEach-Object { "$($_.DnsName)" } | Where-Object { $_ })
    $fan = Invoke-HermesCatalogFanout -Computers $servers -Script {
        $ErrorActionPreference = 'Stop'
        $rels = @()
        try { $rels = @(Get-DhcpServerv4Failover) } catch { if ("$($_.CategoryInfo.Category)" -eq 'ObjectNotFound') { $rels = @() } else { throw } }
        foreach ($f in @($rels | Select-Object -First 100)) {
            $mode = "$($f.Mode)"
            [pscustomobject]@{
                server = $env:COMPUTERNAME; relationship = "$($f.Name)"; partner = "$($f.PartnerServer)"; mode = $mode; state = "$($f.State)"; role = "$($f.ServerRole)"
                scopes = (@($f.ScopeId | ForEach-Object { "$_" }) -join ', ')
                mclt_min = $(if ($f.MaxClientLeadTime) { [int]([timespan]$f.MaxClientLeadTime).TotalMinutes } else { $null })
                load_pct = $(if ($mode -eq 'LoadBalance') { [int]$f.LoadBalancePercent } else { $null })
                reserve_pct = $(if ($mode -eq 'HotStandby') { [int]$f.ReservePercent } else { $null })
            }
        }
    }
    $rows = @($fan.items)
    $notNormal = @($rows | Where-Object { $_['state'] -ne 'Normal' }).Count
    @{ items = @($rows | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); not_normal = $notNormal; servers = $servers.Count; servers_ok = $fan.summary.ok; servers_failed = $fan.summary.failed } }
}
