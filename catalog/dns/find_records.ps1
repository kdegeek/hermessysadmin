<# hermes-catalog
id: dns.find_records
title: Find DNS records for a name
category: DNS & DHCP
description: Looks up a name in every primary forward zone on the domain controller's DNS server and lists every record stored for it (all types), with TTL and the dynamic-update timestamp (empty for static records). A fully qualified name is matched in the zone it belongs to; a single label is looked up in every zone. Use it to find duplicate or conflicting records. Read-only.
module: inbox:DnsServer
target: dc
tier: R
columns: [zone, name, type, data, ttl, timestamp]
tags: [dns, records, find record, a record, cname, duplicate, host record, nslookup, zone]
source: In-box DnsServer (Get-DnsServerZone, Get-DnsServerResourceRecord)
params:
  - {name: Name, type: string, required: true, description: 'Host name or fully qualified name, for example fileserver or fileserver.corp.example.com.'}
#>
param([string]$Name)
Invoke-Op {
    if ($Name -cnotmatch '\A(?=.{1,253}\z)[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,62})(?:\.[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,62}))*\.?\z') {
        throw 'InvalidArguments: Name must be a DNS name (labels of letters, digits, hyphens and underscores separated by dots)'
    }
    if (-not (Get-Command Get-DnsServerResourceRecord -ErrorAction SilentlyContinue)) { throw 'NotInstalled: DnsServer module (RSAT) not present where Hermes runs PowerShell' }
    $dcName = Get-HermesDc
    $dns = Get-HermesDcTarget
    $fqdn = $Name.TrimEnd('.').ToLowerInvariant()
    $single = ($fqdn.IndexOf('.') -lt 0)
    $errs = @()
    $rows = @()
    $zones = @(Get-DnsServerZone @dns | Where-Object { "$($_.ZoneType)" -eq 'Primary' -and -not $_.IsAutoCreated -and -not $_.IsReverseLookupZone } | Sort-Object ZoneName)
    foreach ($z in $zones) {
        $zn = "$($z.ZoneName)".ToLowerInvariant()
        $rel = $null
        if ($single) { $rel = $fqdn }
        elseif ($fqdn -eq $zn) { $rel = '@' }
        elseif ($fqdn.EndsWith(".$zn")) { $rel = $fqdn.Substring(0, $fqdn.Length - $zn.Length - 1) }
        if (-not $rel) { continue }
        try {
            $recs = @(Get-DnsServerResourceRecord -ZoneName $z.ZoneName -Name $rel -ErrorAction Stop @dns)
        } catch {
            if ("$($_.CategoryInfo.Category)" -eq 'ObjectNotFound' -or "$($_.Exception.Message)" -match 'not found|does not exist') { continue }
            $errs += @{ host = $dcName; message = "$($z.ZoneName): $($_.Exception.Message)" }
            continue
        }
        foreach ($r in $recs) {
            $d = $r.RecordData
            $t = "$($r.RecordType)"
            $data = switch ($t) {
                'A'     { "$($d.IPv4Address)" }
                'AAAA'  { "$($d.IPv6Address)" }
                'CNAME' { "$($d.HostNameAlias)" }
                'NS'    { "$($d.NameServer)" }
                'PTR'   { "$($d.PtrDomainName)" }
                'MX'    { "$($d.Preference) $($d.MailExchange)" }
                'SRV'   { "$($d.Priority) $($d.Weight) $($d.Port) $($d.DomainName)" }
                'TXT'   { "$($d.DescriptiveText)" }
                'SOA'   { "$($d.PrimaryServer) serial $($d.SerialNumber)" }
                default { "$t record" }
            }
            $rows += @{ zone = "$($z.ZoneName)"; name = "$($r.HostName)"; type = $t; data = $data; ttl = [int]$r.TimeToLive.TotalSeconds; timestamp = (Iso $r.TimeStamp) }
        }
    }
    @{ items = @($rows | Select-Object -First 500); errors = $errs; summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); zones_searched = $zones.Count; name = $Name } }
}
