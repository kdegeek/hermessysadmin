<# hermes-catalog
id: events.group_membership_changes
title: AD group membership changes
category: Event logs
description: Members added to or removed from security groups (Security 4728/4729 global, 4732/4733 domain local and built-in, 4756/4757 universal) from every domain controller, newest first, with who made the change. Each change is logged only on the DC that made it. Needs "Audit Security Group Management" (on by default for DCs). Changes to member servers' local groups are logged on those servers and are not included.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [time, action, group, member, by, host]
tags: [group membership, added to group, removed from group, 4728, 4732, 4756, domain admins, privileged groups, audit, security log]
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
        $names = @{ 4728 = 'added to global group'; 4729 = 'removed from global group'; 4732 = 'added to local group'; 4733 = 'removed from local group'; 4756 = 'added to universal group'; 4757 = 'removed from universal group' }
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4728, 4729, 4732, 4733, 4756, 4757; StartTime = (Get-Date).AddHours(-$h) } -MaxEvents 2000)
        } catch {
            if ("$($_.FullyQualifiedErrorId)" -like 'NoMatchingEventsFound*') { return }
            throw
        }
        $capped = ($events.Count -ge 2000)
        foreach ($e in $events) {
            $d = @{}
            foreach ($n in ([xml]$e.ToXml()).Event.EventData.Data) { $d["$($n.Name)"] = "$($n.'#text')" }
            $member = $d['MemberName']
            if (-not $member -or $member -eq '-') { $member = $d['MemberSid'] }
            [pscustomobject]@{
                time = $e.TimeCreated.ToUniversalTime().ToString('o')
                action = $names[[int]$e.Id]
                group = "$($d['TargetDomainName'])\$($d['TargetUserName'])"
                member = $member
                by = "$($d['SubjectDomainName'])\$($d['SubjectUserName'])"
                capped = $capped
            }
        }
    }
    $cappedDcs = @($fan.items | Where-Object { $_['capped'] } | ForEach-Object { $_['host'] } | Sort-Object -Unique)
    $rows = @($fan.items | Sort-Object { $_['time'] } -Descending | ForEach-Object { @{ time = $_['time']; action = $_['action']; group = $_['group']; member = $_['member']; by = $_['by']; host = $_['host'] } })
    @{ items = @($rows | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); dcs = $dcs.Count; dcs_ok = $fan.summary.ok; dcs_failed = $fan.summary.failed; hours = $Hours; capped_dcs = $cappedDcs } }
}
