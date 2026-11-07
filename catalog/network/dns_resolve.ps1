<# hermes-catalog
id: network.dns_resolve
title: Resolve a DNS name from computers
category: Network
description: Resolves one DNS name from each chosen computer, using the computer's own resolvers or one DNS server you name, and lists the answer records (type, data, TTL). A failed lookup is a row with the error. Use it to compare what different machines or DNS servers return for the same name.
module: inbox:DnsClient
target: endpoint
tier: R
columns: [host, name, type, data, ttl, error]
tags: [dns, nslookup, resolve, lookup, resolve-dnsname, name resolution, a record, srv, mx]
source: In-box Resolve-DnsName
params:
  - {name: Name, type: string, required: true, description: 'DNS name to resolve, for example intranet.corp.example.com or _ldap._tcp.corp.example.com (letters, digits, hyphens, underscores and dots).'}
  - {name: Type, type: string, default: A, enum: [A, AAAA, A_AAAA, CNAME, MX, NS, PTR, SRV, TXT, SOA], description: Record type to ask for.}
  - {name: Server, type: string, description: Optional DNS server (host name or IP address) to ask instead of the computer's configured resolvers.}
#>
param([string[]]$Computers = @(), [string]$Ou, [string]$Name, [string]$Type = 'A', [string]$Server)
Invoke-Op {
    if ($Name -cnotmatch '\A(?=.{1,253}\z)[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,62})(?:\.[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,62}))*\.?\z') {
        throw 'InvalidArguments: Name must be a DNS name (labels of letters, digits, hyphens and underscores separated by dots, at most 253 characters)'
    }
    if (@('A', 'AAAA', 'A_AAAA', 'CNAME', 'MX', 'NS', 'PTR', 'SRV', 'TXT', 'SOA') -cnotcontains $Type) { throw 'InvalidArguments: Type must be one of A, AAAA, A_AAAA, CNAME, MX, NS, PTR, SRV, TXT, SOA' }
    if ($Server -and $Server -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9.:-]{0,252}\z') { throw 'InvalidArguments: Server must be a host name or IP address (letters, digits, dots, colons and hyphens)' }
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Name, $Type, "$Server") -Script {
        param($n, $t, $srv)
        $ErrorActionPreference = 'Stop'
        $splat = @{ Name = $n; Type = $t; QuickTimeout = $true }
        if ($srv) { $splat.Server = $srv; $splat.DnsOnly = $true }
        try {
            $answers = @(Resolve-DnsName @splat | Where-Object { "$($_.Section)" -eq 'Answer' } | Select-Object -First 100)
        } catch {
            return [pscustomobject]@{ name = $n; type = $t; data = $null; ttl = $null; error = "$($_.Exception.Message)" }
        }
        if ($answers.Count -eq 0) { return [pscustomobject]@{ name = $n; type = $t; data = $null; ttl = $null; error = 'No answer records' } }
        foreach ($r in $answers) {
            $rt = "$($r.Type)"
            $data = switch ($rt) {
                'A'     { "$($r.IPAddress)" }
                'AAAA'  { "$($r.IPAddress)" }
                'CNAME' { "$($r.NameHost)" }
                'NS'    { "$($r.NameHost)" }
                'PTR'   { "$($r.NameHost)" }
                'MX'    { "$($r.Preference) $($r.NameExchange)" }
                'SRV'   { "$($r.Priority) $($r.Weight) $($r.Port) $($r.NameTarget)" }
                'TXT'   { (@($r.Strings) -join ' ') }
                'SOA'   { "$($r.PrimaryServer) $($r.NameAdministrator) serial $($r.SerialNumber)" }
                default { "$r" }
            }
            [pscustomobject]@{ name = "$($r.Name)"; type = $rt; data = $data; ttl = [int]$r.TTL; error = $null }
        }
    }
}
