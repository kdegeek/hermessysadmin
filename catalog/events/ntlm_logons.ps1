<# hermes-catalog
id: events.ntlm_logons
title: NTLM sign-ins to servers
category: Event logs
description: Successful sign-ins that used NTLM instead of Kerberos (Security 4624 with authentication package NTLM) on each computer, grouped by account, source workstation, source address and NTLM version (NTLM V1, NTLM V2 or LM) with a count and the latest time. NTLM V1 and LM rows are listed first; they are the ones to eliminate before restricting NTLM. Omit computers to check every server. Anonymous NTLM sessions appear as ANONYMOUS LOGON.
module: inbox:Microsoft.PowerShell.Diagnostics
target: endpoint
tier: R
columns: [host, account, workstation, source_ip, ntlm_version, count, last]
tags: [ntlm, ntlmv1, ntlm v1, lm, legacy authentication, kerberos, 4624, restrict ntlm, security log]
source: In-box Get-WinEvent -FilterXPath on the Security log (4624, AuthenticationPackageName NTLM)
params:
  - {name: Hours, type: integer, default: 24, minimum: 1, maximum: 720, description: How many hours back to look.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$Hours = 24)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Server
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Hours) -Script {
        param($h)
        $ErrorActionPreference = 'Stop'
        $ms = [int64]$h * 3600000
        $xp = "*[System[EventID=4624 and TimeCreated[timediff(@SystemTime) <= $ms]]] and *[EventData[Data[@Name='AuthenticationPackageName']='NTLM']]"
        try {
            $events = @(Get-WinEvent -LogName Security -FilterXPath $xp -MaxEvents 5000)
        } catch {
            if ("$($_.FullyQualifiedErrorId)" -like 'NoMatchingEventsFound*') { return }
            throw
        }
        $capped = ($events.Count -ge 5000)
        $groups = @{}
        foreach ($e in $events) {
            $d = @{}
            foreach ($n in ([xml]$e.ToXml()).Event.EventData.Data) { $d["$($n.Name)"] = "$($n.'#text')" }
            $account = "$($d['TargetDomainName'])\$($d['TargetUserName'])"
            $ip = "$($d['IpAddress'])" -replace '^::ffff:', ''
            $ver = "$($d['LmPackageName'])"
            $key = "$account|$($d['WorkstationName'])|$ip|$ver"
            $t = $e.TimeCreated.ToUniversalTime().ToString('o')
            if (-not $groups.ContainsKey($key)) { $groups[$key] = @{ account = $account; workstation = "$($d['WorkstationName'])"; source_ip = $ip; ntlm_version = $ver; count = 0; last = $t; capped = $capped } }
            $groups[$key]['count']++
            if ($t -gt $groups[$key]['last']) { $groups[$key]['last'] = $t }
        }
        $sorted = @($groups.Values | Sort-Object @{ Expression = { if ($_['ntlm_version'] -match '\A(NTLM V1|LM)\z') { 0 } else { 1 } } }, @{ Expression = { $_['count'] }; Descending = $true })
        foreach ($g in @($sorted | Select-Object -First 200)) { [pscustomobject]$g }
    }
}
