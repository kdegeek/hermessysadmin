<# hermes-catalog
id: gpo.sysvol_dfsr
title: SYSVOL DFS-R detail
category: Group Policy
description: Per domain controller SYSVOL DFS-R detail. It shows the replicated folder state, the last DFS-R error code, staging and conflict sizes, and whether the SYSVOL and NETLOGON shares exist. Each DC reports on itself, so no cross-server authentication is needed.
module: inbox:GroupPolicy
target: dc
tier: R
columns: [host, state, last_error, stage_mb, conflict_mb, sysvol_share, netlogon_share]
tags: [sysvol, dfsr, dfs-r, replication, staging, conflict, netlogon, domain controllers]
source: In-box CIM (root\microsoftdfs DfsrReplicatedFolderInfo) and SmbShare, fanned out to each DC
#>
param()
Invoke-Op {
    $dcs = @(Get-ADDomainController -Filter * | ForEach-Object { $_.HostName } | Where-Object { $_ })
    $fan = Invoke-HermesCatalogFanout -Computers $dcs -Script {
        $ErrorActionPreference = 'Stop'
        $names = @{ 0 = 'Uninitialized'; 1 = 'Initialized'; 2 = 'Initial sync'; 3 = 'Auto recovery'; 4 = 'Normal'; 5 = 'In error' }
        $rf = @(Get-CimInstance -Namespace 'root\microsoftdfs' -ClassName DfsrReplicatedFolderInfo | Where-Object { "$($_.ReplicatedFolderName)" -like 'SYSVOL*' })
        $shares = @(Get-SmbShare -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        $state = 'no SYSVOL folder'
        $lastErr = $null
        $stage = $null
        $conf = $null
        if ($rf.Count -gt 0) {
            $k = [int]$rf[0].State
            if ($names.ContainsKey($k)) { $state = $names[$k] } else { $state = "state $k" }
            $lastErr = [int64]$rf[0].LastErrorCode
            $stage = [int64]$rf[0].CurrentStageSizeInMb
            $conf = [int64]$rf[0].CurrentConflictSizeInMb
        }
        [pscustomobject]@{
            state = $state; last_error = $lastErr; stage_mb = $stage; conflict_mb = $conf
            sysvol_share = ($shares -contains 'SYSVOL'); netlogon_share = ($shares -contains 'NETLOGON')
        }
    }
    @{ items = @($fan.items | Select-Object -First 500); errors = $fan.errors; summary = @{ total = @($fan.items).Count; truncated = (@($fan.items).Count -gt 500); dcs = $dcs.Count; dcs_ok = $fan.summary.ok; dcs_failed = $fan.summary.failed } }
}
