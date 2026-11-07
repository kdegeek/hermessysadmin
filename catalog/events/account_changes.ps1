<# hermes-catalog
id: events.account_changes
title: User account created, deleted, enabled, disabled or reset
category: Event logs
description: User account lifecycle events from every domain controller, newest first, with who did it - created (4720), enabled (4722), password reset by someone else (4724), disabled (4725), deleted (4726) and renamed (4781). A new account also logs 4722 and 4724 when it is created with a password and enabled. Needs "Audit User Account Management" (on by default for DCs). No password data is in these events.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [time, action, account, by, host]
tags: [account created, account deleted, user created, password reset, 4720, 4726, 4724, 4725, disabled, enabled, renamed, audit, security log]
source: In-box Get-WinEvent -FilterHashtable run locally on each DC through the fan-out
params:
  - {name: Hours, type: integer, default: 168, minimum: 1, maximum: 720, description: How many hours back to look.}
#>
param([int]$Hours = 168)
Invoke-Op {
    $dcs = @(Get-ADDomainController -Filter * | ForEach-Object { $_.HostName } | Where-Object { $_ })
    $fan = Invoke-HermesCatalogFanout -Computers $dcs -ArgumentList @($Hours) -Script {
        param($h)
        $ErrorActionPreference = 'Stop'
        $names = @{ 4720 = 'created'; 4722 = 'enabled'; 4724 = 'password reset'; 4725 = 'disabled'; 4726 = 'deleted'; 4781 = 'renamed' }
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4720, 4722, 4724, 4725, 4726, 4781; StartTime = (Get-Date).AddHours(-$h) } -MaxEvents 2000)
        } catch {
            if ("$($_.FullyQualifiedErrorId)" -like 'NoMatchingEventsFound*') { return }
            throw
        }
        $capped = ($events.Count -ge 2000)
        foreach ($e in $events) {
            $d = @{}
            foreach ($n in ([xml]$e.ToXml()).Event.EventData.Data) { $d["$($n.Name)"] = "$($n.'#text')" }
            $account = "$($d['TargetDomainName'])\$($d['TargetUserName'])"
            if ([int]$e.Id -eq 4781) { $account = "$($d['TargetDomainName'])\$($d['OldTargetUserName']) -> $($d['NewTargetUserName'])" }
            [pscustomobject]@{
                time = $e.TimeCreated.ToUniversalTime().ToString('o')
                action = $names[[int]$e.Id]
                account = $account
                by = "$($d['SubjectDomainName'])\$($d['SubjectUserName'])"
                capped = $capped
            }
        }
    }
    $cappedDcs = @($fan.items | Where-Object { $_['capped'] } | ForEach-Object { $_['host'] } | Sort-Object -Unique)
    $rows = @($fan.items | Sort-Object { $_['time'] } -Descending | ForEach-Object { @{ time = $_['time']; action = $_['action']; account = $_['account']; by = $_['by']; host = $_['host'] } })
    @{ items = @($rows | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); dcs = $dcs.Count; dcs_ok = $fan.summary.ok; dcs_failed = $fan.summary.failed; hours = $Hours; capped_dcs = $cappedDcs } }
}
