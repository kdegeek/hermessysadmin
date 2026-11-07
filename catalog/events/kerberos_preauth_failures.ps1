<# hermes-catalog
id: events.kerberos_preauth_failures
title: Kerberos pre-authentication failures (4771)
category: Event logs
description: Kerberos pre-authentication failures (Security 4771) from every domain controller, grouped by account, client address and failure reason with a count and the latest time. Reason 0x18 is a wrong password; many 0x18 failures for one account from one address usually means a stale saved password (a mapped drive, service or phone), many accounts from one address can be password spraying. Needs "Audit Kerberos Authentication Service" failure auditing.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [account, source_ip, reason, count, last]
tags: [kerberos, 4771, pre-authentication, preauth, bad password, password spray, 0x18, failed logons, security log]
source: In-box Get-WinEvent -FilterHashtable run locally on each DC through the fan-out
params:
  - {name: Hours, type: integer, default: 24, minimum: 1, maximum: 720, description: How many hours back to look.}
#>
param([int]$Hours = 24)
Invoke-Op {
    $dcs = @(Get-ADDomainController -Filter * | ForEach-Object { $_.HostName } | Where-Object { $_ })
    $fan = Invoke-HermesCatalogFanout -Computers $dcs -ArgumentList @($Hours) -Script {
        param($h)
        $ErrorActionPreference = 'Stop'
        $reasons = @{ '0x18' = '0x18 wrong password'; '0x12' = '0x12 account disabled, expired or locked out'; '0x17' = '0x17 password expired'; '0x25' = '0x25 clock skew'; '0x10' = '0x10 smart card logon not supported'; '0x6' = '0x6 unknown account' }
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4771; StartTime = (Get-Date).AddHours(-$h) } -MaxEvents 5000)
        } catch {
            if ("$($_.FullyQualifiedErrorId)" -like 'NoMatchingEventsFound*') { return }
            throw
        }
        $groups = @{}
        $capped = ($events.Count -ge 5000)
        foreach ($e in $events) {
            $d = @{}
            foreach ($n in ([xml]$e.ToXml()).Event.EventData.Data) { $d["$($n.Name)"] = "$($n.'#text')" }
            $ip = "$($d['IpAddress'])" -replace '^::ffff:', ''
            $code = "$($d['Status'])".ToLowerInvariant()
            $reason = $(if ($reasons.ContainsKey($code)) { $reasons[$code] } else { $code })
            $key = "$($d['TargetUserName'])|$ip|$reason"
            $t = $e.TimeCreated.ToUniversalTime().ToString('o')
            if (-not $groups.ContainsKey($key)) { $groups[$key] = @{ account = $d['TargetUserName']; source_ip = $ip; reason = $reason; count = 0; last = $t } }
            $groups[$key]['count']++
            if ($t -gt $groups[$key]['last']) { $groups[$key]['last'] = $t }
        }
        foreach ($g in $groups.Values) { $g['capped'] = $capped; [pscustomobject]$g }
    }
    $merged = @{}
    $cappedDcs = @($fan.items | Where-Object { $_['capped'] } | ForEach-Object { $_['host'] } | Sort-Object -Unique)
    foreach ($r in $fan.items) {
        $key = "$($r['account'])|$($r['source_ip'])|$($r['reason'])"
        if (-not $merged.ContainsKey($key)) { $merged[$key] = @{ account = $r['account']; source_ip = $r['source_ip']; reason = $r['reason']; count = 0; last = $r['last'] } }
        $merged[$key]['count'] += [int]$r['count']
        if ("$($r['last'])" -gt "$($merged[$key]['last'])") { $merged[$key]['last'] = $r['last'] }
    }
    $all = @($merged.Values | Sort-Object { $_['count'] } -Descending)
    @{ items = @($all | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $all.Count; truncated = ($all.Count -gt 500); dcs = $dcs.Count; dcs_ok = $fan.summary.ok; dcs_failed = $fan.summary.failed; hours = $Hours; capped_dcs = $cappedDcs } }
}
