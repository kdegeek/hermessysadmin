<# hermes-catalog
id: events.audit_tampering
title: Event log cleared or audit policy changed
category: Event logs
description: Signs that auditing was tampered with on each computer, newest first - the Security log was cleared (Security 1102), another log was cleared (System 104) or the audit policy was changed (Security 4719, with the subcategory and change). Omit computers to check every server, domain controllers included. Some 4719 events are expected when a GPO changes the audit policy.
module: inbox:Microsoft.PowerShell.Diagnostics
target: endpoint
tier: R
columns: [host, time, event, by, detail]
tags: [log cleared, 1102, 104, audit policy, 4719, tampering, anti-forensics, security log, event log]
source: In-box Get-WinEvent -FilterHashtable (Security 1102 and 4719, System 104)
params:
  - {name: Days, type: integer, default: 30, minimum: 1, maximum: 365, description: How many days back to look.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$Days = 30)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Server
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Days) -Script {
        param($days)
        $ErrorActionPreference = 'Stop'
        $since = (Get-Date).AddDays(-$days)
        $events = @()
        foreach ($q in @(
            @{ LogName = 'Security'; Id = 1102, 4719; StartTime = $since },
            @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Eventlog'; Id = 104; StartTime = $since })) {
            try {
                $events += @(Get-WinEvent -FilterHashtable $q -MaxEvents 200)
            } catch {
                if ("$($_.FullyQualifiedErrorId)" -like 'NoMatching*') { continue }
                throw
            }
        }
        foreach ($e in @($events | Sort-Object TimeCreated -Descending | Select-Object -First 200)) {
            $x = [xml]$e.ToXml()
            $d = @{}
            foreach ($n in @($x.Event.EventData.Data)) { if ($n -and $n.Name) { $d["$($n.Name)"] = "$($n.'#text')" } }
            if ($x.Event.UserData) { foreach ($c in @($x.Event.UserData.ChildNodes)) { foreach ($f in @($c.ChildNodes)) { $d["$($f.LocalName)"] = "$($f.InnerText)" } } }
            $id = [int]$e.Id
            $detail = ''
            $what = ''
            if ($id -eq 1102) { $what = 'Security log cleared' }
            elseif ($id -eq 104) { $what = 'Event log cleared'; $detail = "log: $($d['Channel'])" }
            else {
                $what = 'Audit policy changed'
                $m = "$($e.Message)"
                $sub = [regex]::Match($m, '(?m)^\s*Subcategory:\s*(.+?)\s*$')
                $chg = [regex]::Match($m, '(?m)^\s*Changes:\s*(.+?)\s*$')
                if ($sub.Success -or $chg.Success) { $detail = "$($sub.Groups[1].Value): $($chg.Groups[1].Value)" } else { $detail = "subcategory $($d['SubcategoryGuid']): $($d['AuditPolicyChanges'])" }
            }
            [pscustomobject]@{ time = $e.TimeCreated.ToUniversalTime().ToString('o'); event = $what; by = "$($d['SubjectDomainName'])\$($d['SubjectUserName'])"; detail = $detail }
        }
    }
}
