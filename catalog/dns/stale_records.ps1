<# hermes-catalog
id: dns.stale_records
title: Stale DNS records
category: DNS & DHCP
description: Dynamic A records in a zone whose timestamp is older than N days, which scavenging has not removed. Static records have no timestamp and are never listed.
module: inbox:DnsServer
target: dc
tier: R
columns: [name, ip, timestamp]
tags: [dns, stale, scavenging, old records, dynamic records, a records, cleanup]
source: In-box DnsServer (Get-DnsServerResourceRecord)
params:
  - {name: Zone, type: string, required: true, description: DNS zone name to check, for example corp.example.com.}
  - {name: Days, type: integer, default: 30, minimum: 1, maximum: 3650, description: Records last refreshed more than this many days ago are listed.}
#>
param([string]$Zone, [int]$Days = 30)
Invoke-Op {
    if ($Zone -notmatch '^[A-Za-z0-9.-]{1,253}$') { throw 'Zone must be a DNS zone name (letters, digits, dots and hyphens, at most 253 characters)' }
    if (-not (Get-Command Get-DnsServerResourceRecord -ErrorAction SilentlyContinue)) { throw 'NotInstalled: DnsServer module not present on the jump host' }
    $cut = (Get-Date).AddDays(-$Days)
    $dns = Get-HermesDcTarget
    $rows = @(Get-DnsServerResourceRecord -ZoneName $Zone -RRType A @dns |
        Where-Object { $_.TimeStamp -and $_.TimeStamp -lt $cut } |
        Sort-Object TimeStamp |
        ForEach-Object { @{ name = "$($_.HostName)"; ip = "$($_.RecordData.IPv4Address)"; timestamp = (Iso $_.TimeStamp) } })
    @{ items = @($rows | Select-Object -First 500); summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); zone = $Zone; days = $Days } }
}
