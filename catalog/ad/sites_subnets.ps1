<# hermes-catalog
id: ad.sites_subnets
title: AD sites, subnets and site links
category: AD hygiene
description: AD sites with their subnet and domain controller counts, every subnet with its site and location, site links with cost, replication interval and member sites, and each domain controller's IPv4 address checked against the subnets. Issues flag subnets without a site, sites with no subnet or not in any site link, DC addresses not covered by any subnet and DCs whose address maps to a different site than the one they sit in. Only IPv4 subnets are matched.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [kind, name, site, detail, issue]
tags: [sites, subnets, site links, ad sites and services, replication topology, dc site, site coverage, client site]
source: In-box ActiveDirectory (Get-ADReplicationSite, Get-ADReplicationSubnet, Get-ADReplicationSiteLink, Get-ADDomainController)
#>
param()
Invoke-Op {
    function ConvertTo-IpNumber([string]$s) {
        $a = $null
        if (-not [System.Net.IPAddress]::TryParse($s, [ref]$a)) { return $null }
        if ($a.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $null }
        $b = $a.GetAddressBytes()
        return ([int64]$b[0] * 16777216 + [int64]$b[1] * 65536 + [int64]$b[2] * 256 + [int64]$b[3])
    }
    $sites = @(Get-ADReplicationSite -Filter * | Sort-Object Name)
    $subnets = @(Get-ADReplicationSubnet -Filter * -Properties Site, Location | Sort-Object Name)
    $links = @(Get-ADReplicationSiteLink -Filter * -Properties Cost, ReplicationFrequencyInMinutes, SitesIncluded | Sort-Object Name)
    $dcs = @(Get-ADDomainController -Filter * | Sort-Object Name)

    $nets = @(foreach ($sn in $subnets) {
        $parts = "$($sn.Name)" -split '/'
        if ($parts.Count -ne 2) { continue }
        $base = ConvertTo-IpNumber $parts[0]
        $len = 0
        if ($null -eq $base -or -not [int]::TryParse($parts[1], [ref]$len) -or $len -lt 0 -or $len -gt 32) { continue }
        $size = [math]::Pow(2, 32 - $len)
        @{ name = "$($sn.Name)"; site = (Get-CnName "$($sn.Site)"); len = $len; size = $size; net = [int64][math]::Floor($base / $size) }
    })
    $linked = @{}
    foreach ($l in $links) { foreach ($s in @($l.SitesIncluded)) { $linked[(Get-CnName "$s")] = $true } }
    $rows = New-Object System.Collections.ArrayList
    foreach ($s in $sites) {
        $nSub = @($subnets | Where-Object { (Get-CnName "$($_.Site)") -eq $s.Name }).Count
        $nDc = @($dcs | Where-Object { $_.Site -eq $s.Name }).Count
        $issue = @()
        if ($nSub -eq 0) { $issue += 'no subnets' }
        if ($sites.Count -gt 1 -and -not $linked.ContainsKey($s.Name)) { $issue += 'not in any site link' }
        [void]$rows.Add(@{ kind = 'site'; name = $s.Name; site = $s.Name; detail = "$nSub subnet(s), $nDc DC(s)"; issue = ($issue -join '; ') })
    }
    foreach ($sn in $subnets) {
        $site = Get-CnName "$($sn.Site)"
        [void]$rows.Add(@{ kind = 'subnet'; name = "$($sn.Name)"; site = $site; detail = "$($sn.Location)"; issue = $(if (-not $site) { 'no site assigned' } else { '' }) })
    }
    foreach ($l in $links) {
        $members = @($l.SitesIncluded | ForEach-Object { Get-CnName "$_" })
        [void]$rows.Add(@{ kind = 'site_link'; name = $l.Name; site = ($members -join ', ')
                           detail = "cost $($l.Cost), every $($l.ReplicationFrequencyInMinutes) min"
                           issue = $(if ($members.Count -lt 2) { 'fewer than two sites' } else { '' }) })
    }
    foreach ($dc in $dcs) {
        $ip = ConvertTo-IpNumber "$($dc.IPv4Address)"
        $best = $null
        if ($null -ne $ip) {
            foreach ($n in $nets) {
                if ([int64][math]::Floor($ip / $n.size) -eq $n.net -and ($null -eq $best -or $n.len -gt $best.len)) { $best = $n }
            }
        }
        $issue = ''
        $detail = "$($dc.IPv4Address)"
        if ($null -eq $ip) { $issue = 'no IPv4 address recorded' }
        elseif ($null -eq $best) { $issue = 'address not in any subnet' }
        else {
            $detail = "$($dc.IPv4Address) in $($best.name)"
            if ($best.site -ne $dc.Site) { $issue = "subnet maps to site $($best.site)" }
        }
        [void]$rows.Add(@{ kind = 'dc'; name = $dc.HostName; site = $dc.Site; detail = $detail; issue = $issue })
    }
    $all = @($rows)
    @{ items = @($all | Select-Object -First 500)
       summary = @{ total = $all.Count; truncated = ($all.Count -gt 500); sites = $sites.Count; subnets = $subnets.Count; site_links = $links.Count
                    dcs = $dcs.Count; issues = @($all | Where-Object { $_['issue'] }).Count } }
}
