<# hermes-catalog
id: events.lockouts
title: Account lockouts (4740)
category: Event logs
description: Account lockout events (Security 4740) from every domain controller with the computer that caused each lockout. Duplicates seen on several DCs are merged.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [account, caller_computer, time]
tags: [lockout, locked out, 4740, bad password, account lockout, security log]
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
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4740; StartTime = (Get-Date).AddHours(-$h) } -MaxEvents 1000)
        } catch {
            if ("$($_.FullyQualifiedErrorId)" -like 'NoMatchingEventsFound*') { return }
            throw
        }
        foreach ($e in $events) {
            $d = @{}
            foreach ($n in ([xml]$e.ToXml()).Event.EventData.Data) { $d["$($n.Name)"] = "$($n.'#text')" }
            [pscustomobject]@{ account = $d['TargetUserName']; caller_computer = $d['TargetDomainName']; time = $e.TimeCreated.ToUniversalTime().ToString('o') }
        }
    }
    # The same lockout is logged on several DCs; merge on account + caller + minute.
    $seen = @{}
    $rows = @()
    foreach ($r in $fan.items) {
        $t = "$($r['time'])"
        $key = "$($r['account'])|$($r['caller_computer'])|$($t.Substring(0, [math]::Min(16, $t.Length)))"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $rows += @{ account = $r['account']; caller_computer = $r['caller_computer']; time = $r['time'] }
    }
    $rows = @($rows | Sort-Object { $_['time'] } -Descending)
    @{ items = @($rows | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); dcs = $dcs.Count; dcs_ok = $fan.summary.ok; dcs_failed = $fan.summary.failed; hours = $Hours } }
}
