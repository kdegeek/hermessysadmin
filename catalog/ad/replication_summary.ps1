<# hermes-catalog
id: ad.replication_summary
title: Replication summary
category: AD hygiene
description: Replication partners and failures for every domain controller. Partner metadata and failures come from the local DC; each DC then reports its own inbound replication state (repadmin /showrepl run locally on that DC), so no DC-to-DC remoting is needed from the jump host.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [kind, host, partner, naming_context, last_success, last_attempt, first_failure, failures, error]
tags: [replication, repadmin, replsummary, partners, failures, health, domain controllers]
source: In-box ActiveDirectory (Get-ADReplicationPartnerMetadata, Get-ADReplicationFailure) and repadmin.exe
#>
param()
Invoke-Op {
    $me = $env:COMPUTERNAME
    $errors = @()
    $rows = @()
    try {
        $rows += @(Get-ADReplicationPartnerMetadata -Target $me -Scope Server -ErrorAction Stop | ForEach-Object {
            @{ kind = 'partner'; host = $me; partner = "$($_.PartnerAddress)"; naming_context = "$($_.Partition)"
               last_success = (Iso $_.LastReplicationSuccess); last_attempt = (Iso $_.LastReplicationAttempt); first_failure = $null
               failures = [int]$_.ConsecutiveReplicationFailures; error = "$($_.LastReplicationResult)" } })
    } catch { $errors += @{ host = $me; message = "partner metadata: $($_.Exception.Message)" } }
    try {
        $rows += @(Get-ADReplicationFailure -Target $me -ErrorAction Stop | ForEach-Object {
            @{ kind = 'failure'; host = $me; partner = "$($_.Partner)"; naming_context = $null
               last_success = $null; last_attempt = $null; first_failure = (Iso $_.FirstFailureTime)
               failures = [int]$_.FailureCount; error = "$($_.LastError) $($_.FailureType)".Trim() } })
    } catch { $errors += @{ host = $me; message = "replication failures: $($_.Exception.Message)" } }
    $dcs = @(Get-ADDomainController -Filter * | ForEach-Object { $_.HostName } | Where-Object { $_ })
    $fan = Invoke-HermesCatalogFanout -Computers $dcs -Script {
        $ErrorActionPreference = 'Stop'
        $out = & { $ErrorActionPreference = 'Continue'; repadmin.exe /showrepl $env:COMPUTERNAME /csv 2>$null }
        $lines = @($out | Where-Object { $_ -and ("$_".Trim() -ne '') })
        if ($lines.Count -lt 2) { throw 'repadmin returned no replication data' }
        foreach ($r in @($lines | ConvertFrom-Csv)) {
            $n = 0
            [void][int]::TryParse("$($r.'Number of Failures')", [ref]$n)
            [pscustomobject]@{
                kind = 'repadmin'; partner = "$($r.'Source DSA')"; naming_context = "$($r.'Naming Context')"
                last_success = "$($r.'Last Success Time')"; last_attempt = $null; first_failure = "$($r.'Last Failure Time')"
                failures = $n; error = "$($r.'Last Failure Status')"
            }
        }
    }
    $rows += @($fan.items)
    $errors += @($fan.errors)
    @{ items = @($rows | Select-Object -First 500); errors = $errors; summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); dcs = $dcs.Count; dcs_ok = $fan.summary.ok; dcs_failed = $fan.summary.failed } }
}
