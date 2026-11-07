<# hermes-catalog
id: ad.last_backup
title: Last AD backup
category: AD hygiene
description: When each naming context on this domain controller was last backed up, from the dSASignature replication metadata, and how many days ago.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [naming_context, last_backup, days_since]
tags: [backup, last backup, dsasignature, system state, recovery, tombstone, naming context]
source: In-box ActiveDirectory (Get-ADReplicationAttributeMetadata)
#>
param()
Invoke-Op {
    $me = $env:COMPUTERNAME
    $errors = @()
    $rows = @()
    foreach ($nc in @((Get-ADRootDSE).namingContexts)) {
        try {
            $m = @(Get-ADReplicationAttributeMetadata -Object $nc -Server $me -ErrorAction Stop | Where-Object { $_.AttributeName -eq 'dSASignature' })
            $when = $null
            if ($m.Count -gt 0) { $when = $m[0].LastOriginatingChangeTime }
            $days = $null
            if ($when) { $days = [int]((Get-Date) - $when).TotalDays }
            $rows += @(@{ naming_context = "$nc"; last_backup = (Iso $when); days_since = $days })
        } catch { $errors += @{ host = $nc; message = "$($_.Exception.Message)" } }
    }
    @{ items = @($rows | Select-Object -First 500); errors = $errors; summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500) } }
}
