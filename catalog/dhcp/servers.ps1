<# hermes-catalog
id: dhcp.servers
title: DHCP servers and authorization
category: DNS & DHCP
description: Every DHCP server authorized in Active Directory and what it reports about itself - whether it is reachable, authorized and domain joined, the DHCP service state, its IPv4 scope count, conflict detection, audit logging, DNS dynamic update mode and name protection, and whether a dedicated DNS update credential is set (yes or no only; the credential is never read). A DHCP server on a DC with no dedicated credential registers records as the DC.
module: inbox:DhcpServer
target: dc
tier: R
columns: [server, ip, reachable, authorized, domain_joined, service, scopes, conflict_detection, audit_log, dns_updates, name_protection, dns_credential_set]
tags: [dhcp, servers, authorized, authorization, rogue dhcp, audit log, dns credential, conflict detection]
source: In-box DhcpServer (Get-DhcpServerInDC, Get-DhcpServerSetting, Get-DhcpServerAuditLog, Get-DhcpServerv4DnsSetting, Get-DhcpServerDnsCredential), fanned out to each DHCP server
#>
param()
Invoke-Op {
    if (-not (Get-Command Get-DhcpServerInDC -ErrorAction SilentlyContinue)) { throw 'NotInstalled: DhcpServer module (RSAT) not present where Hermes runs PowerShell' }
    $inDc = @(Get-DhcpServerInDC | Where-Object { $_.DnsName })
    $servers = @($inDc | ForEach-Object { "$($_.DnsName)" })
    $fan = Invoke-HermesCatalogFanout -Computers $servers -Script {
        $ErrorActionPreference = 'Stop'
        $s = Get-DhcpServerSetting
        $audit = $null
        try { $audit = [bool](Get-DhcpServerAuditLog).Enable } catch { $audit = $null }
        $dnsUpd = $null; $prot = $null
        try { $d = Get-DhcpServerv4DnsSetting; $dnsUpd = "$($d.DynamicUpdates)"; $prot = [bool]$d.NameProtection } catch { }
        $cred = $null
        try { $cred = [bool]("$((Get-DhcpServerDnsCredential).UserName)".Trim()) } catch { $cred = $null }
        [pscustomobject]@{
            authorized = [bool]$s.IsAuthorized; domain_joined = [bool]$s.IsDomainJoined; service = "$((Get-Service -Name DHCPServer).Status)"
            scopes = @(Get-DhcpServerv4Scope).Count; conflict_detection = [int]$s.ConflictDetectionAttempts; audit_log = $audit
            dns_updates = $dnsUpd; name_protection = $prot; dns_credential_set = $cred
        }
    }
    $byHost = @{}
    foreach ($r in $fan.items) { $byHost[("$($r['host'])" -split '\.')[0].ToLowerInvariant()] = $r }
    $rows = @(foreach ($s in $inDc) {
        $r = $byHost[("$($s.DnsName)" -split '\.')[0].ToLowerInvariant()]
        if ($r) {
            @{ server = "$($s.DnsName)"; ip = "$($s.IPAddress)"; reachable = $true; authorized = $r['authorized']; domain_joined = $r['domain_joined']; service = $r['service']
               scopes = $r['scopes']; conflict_detection = $r['conflict_detection']; audit_log = $r['audit_log']; dns_updates = $r['dns_updates']
               name_protection = $r['name_protection']; dns_credential_set = $r['dns_credential_set'] }
        } else {
            @{ server = "$($s.DnsName)"; ip = "$($s.IPAddress)"; reachable = $false; authorized = $null; domain_joined = $null; service = $null; scopes = $null
               conflict_detection = $null; audit_log = $null; dns_updates = $null; name_protection = $null; dns_credential_set = $null }
        }
    })
    @{ items = @($rows | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); unreachable = @($rows | Where-Object { -not $_.reachable }).Count; servers_ok = $fan.summary.ok; servers_failed = $fan.summary.failed } }
}
