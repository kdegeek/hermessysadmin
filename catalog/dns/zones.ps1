<# hermes-catalog
id: dns.zones
title: DNS zones
category: DNS & DHCP
description: DNS zones on the domain controller (the DC Hermes runs on, otherwise the PDC emulator) with zone type, whether they are AD-integrated, and scavenging (aging) settings. Needs the DnsServer RSAT module where Hermes runs PowerShell.
module: inbox:DnsServer
target: dc
tier: R
columns: [zone, type, ds_integrated, aging, refresh, no_refresh]
tags: [dns, zones, scavenging, aging, ad integrated, refresh interval, forward, reverse]
source: In-box DnsServer (Get-DnsServerZone, Get-DnsServerZoneAging)
#>
param()
Invoke-Op {
    $dcName = Get-HermesDc
    if (-not (Get-Command Get-DnsServerZone -ErrorAction SilentlyContinue)) { throw 'NotInstalled: DnsServer module (RSAT) not present where Hermes runs PowerShell' }
    $errs = @()
    $rows = @()
    $dns = Get-HermesDcTarget
    foreach ($z in @(Get-DnsServerZone @dns | Sort-Object ZoneName)) {
        $aging = $null
        $refresh = $null
        $noRefresh = $null
        if ("$($z.ZoneType)" -eq 'Primary' -and -not $z.IsAutoCreated) {
            try {
                $a = Get-DnsServerZoneAging -Name $z.ZoneName -ErrorAction Stop @dns
                $aging = [bool]$a.AgingEnabled
                $refresh = [int]$a.RefreshInterval.TotalHours
                $noRefresh = [int]$a.NoRefreshInterval.TotalHours
            } catch { $errs += @{ host = $dcName; message = "$($z.ZoneName): $($_.Exception.Message)" } }
        }
        $rows += @{ zone = "$($z.ZoneName)"; type = "$($z.ZoneType)"; ds_integrated = [bool]$z.IsDsIntegrated; aging = $aging; refresh = $refresh; no_refresh = $noRefresh }
    }
    @{ items = @($rows | Select-Object -First 500); errors = $errs; summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); intervals_unit = 'hours' } }
}
