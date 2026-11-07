<# hermes-catalog
id: events.failed_logons
title: Failed logons (4625) summary
category: Event logs
description: Failed sign-in events (Security 4625) from every domain controller, grouped by account, source IP and workstation with a count and the latest time. Each DC reads its own log.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [account, source_ip, workstation, count, last]
tags: [failed logons, 4625, brute force, password spray, security log, audit failure, logon failures]
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
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4625; StartTime = (Get-Date).AddHours(-$h) } -MaxEvents 5000)
        } catch {
            if ("$($_.FullyQualifiedErrorId)" -like 'NoMatchingEventsFound*') { return }
            throw
        }
        $groups = @{}
        $capped = ($events.Count -ge 5000)
        foreach ($e in $events) {
            $d = @{}
            foreach ($n in ([xml]$e.ToXml()).Event.EventData.Data) { $d["$($n.Name)"] = "$($n.'#text')" }
            $key = "$($d['TargetUserName'])|$($d['IpAddress'])|$($d['WorkstationName'])"
            $t = $e.TimeCreated.ToUniversalTime().ToString('o')
            if (-not $groups.ContainsKey($key)) { $groups[$key] = @{ account = $d['TargetUserName']; source_ip = $d['IpAddress']; workstation = $d['WorkstationName']; count = 0; last = $t } }
            $groups[$key]['count']++
            if ($t -gt $groups[$key]['last']) { $groups[$key]['last'] = $t }
        }
        foreach ($g in $groups.Values) { $g['capped'] = $capped; [pscustomobject]$g }
    }
    $merged = @{}
    $cappedDcs = @($fan.items | Where-Object { $_['capped'] } | ForEach-Object { $_['host'] } | Sort-Object -Unique)
    foreach ($r in $fan.items) {
        $key = "$($r['account'])|$($r['source_ip'])|$($r['workstation'])"
        if (-not $merged.ContainsKey($key)) { $merged[$key] = @{ account = $r['account']; source_ip = $r['source_ip']; workstation = $r['workstation']; count = 0; last = $r['last'] } }
        $merged[$key]['count'] += [int]$r['count']
        if ("$($r['last'])" -gt "$($merged[$key]['last'])") { $merged[$key]['last'] = $r['last'] }
    }
    $all = @($merged.Values | Sort-Object { $_['count'] } -Descending)
    @{ items = @($all | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $all.Count; truncated = ($all.Count -gt 500); dcs = $dcs.Count; dcs_ok = $fan.summary.ok; dcs_failed = $fan.summary.failed; hours = $Hours; capped_dcs = $cappedDcs } }
}
