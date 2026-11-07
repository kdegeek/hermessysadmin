<# hermes-catalog
id: events.logon_types
title: Logon type summary
category: Event logs
description: Successful sign-ins (Security 4624) on each computer counted by logon type - interactive, network, batch, service, unlock, network cleartext, new credentials (runas /netonly), Remote Desktop and cached - with the number of distinct accounts and up to five example accounts. Reads at most the newest 5000 sign-ins per computer; capped says when that limit was reached.
module: inbox:Microsoft.PowerShell.Diagnostics
target: endpoint
tier: R
columns: [host, logon_type, type_name, count, accounts, sample_accounts, capped]
tags: [logon types, 4624, logon type 3, logon type 10, network logon, interactive, cleartext, batch, service logon, security log]
source: In-box Get-WinEvent -FilterHashtable (Security 4624)
params:
  - {name: Hours, type: integer, default: 24, minimum: 1, maximum: 720, description: How many hours back to look.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$Hours = 24)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Hours) -Script {
        param($h)
        $ErrorActionPreference = 'Stop'
        $typeNames = @{ 2 = 'Interactive'; 3 = 'Network'; 4 = 'Batch'; 5 = 'Service'; 7 = 'Unlock'; 8 = 'NetworkCleartext'; 9 = 'NewCredentials'; 10 = 'RemoteInteractive'; 11 = 'CachedInteractive'; 12 = 'CachedRemoteInteractive'; 13 = 'CachedUnlock' }
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4624; StartTime = (Get-Date).AddHours(-$h) } -MaxEvents 5000)
        } catch {
            if ("$($_.FullyQualifiedErrorId)" -like 'NoMatchingEventsFound*') { return }
            throw
        }
        $capped = ($events.Count -ge 5000)
        $groups = @{}
        foreach ($e in $events) {
            # 4624 fields 5, 6 and 8 are TargetUserName, TargetDomainName and LogonType in every event version.
            $p = @($e.Properties)
            if ($p.Count -lt 9) { continue }
            $type = [int]$p[8].Value
            $acct = "$($p[6].Value)\$($p[5].Value)"
            if (-not $groups.ContainsKey($type)) { $groups[$type] = @{ count = 0; accounts = @{} } }
            $groups[$type]['count']++
            $groups[$type]['accounts'][$acct] = $true
        }
        foreach ($type in @($groups.Keys | Sort-Object)) {
            $g = $groups[$type]
            [pscustomobject]@{
                logon_type = $type
                type_name = $(if ($typeNames.ContainsKey($type)) { $typeNames[$type] } else { "Type $type" })
                count = $g['count']
                accounts = $g['accounts'].Count
                sample_accounts = @($g['accounts'].Keys | Sort-Object | Select-Object -First 5)
                capped = $capped
            }
        }
    }
}
