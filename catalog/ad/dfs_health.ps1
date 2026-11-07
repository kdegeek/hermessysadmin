<# hermes-catalog
id: ad.dfs_health
title: SYSVOL DFS-R health
category: AD hygiene
description: Per domain controller SYSVOL replication state (DFS-R), whether the SYSVOL and NETLOGON shares exist and whether the DFSR service is running. Each DC reports on itself, so no remote CIM access is needed.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [host, sysvol_state, sysvol_share, netlogon_share, dfsr_service, healthy]
tags: [dfs, dfsr, sysvol, netlogon, replication, domain controllers, health]
source: In-box CIM (root\microsoftdfs DfsrReplicatedFolderInfo), SmbShare and Service, fanned out to each DC
#>
param()
Invoke-Op {
    $dcs = @(Get-ADDomainController -Filter * | ForEach-Object { $_.HostName } | Where-Object { $_ })
    $fan = Invoke-HermesCatalogFanout -Computers $dcs -Script {
        $ErrorActionPreference = 'Stop'
        $names = @{ 0 = 'Uninitialized'; 1 = 'Initialized'; 2 = 'Initial sync'; 3 = 'Auto recovery'; 4 = 'Normal'; 5 = 'In error' }
        $state = 'unavailable'
        try {
            $rf = @(Get-CimInstance -Namespace 'root\microsoftdfs' -ClassName DfsrReplicatedFolderInfo | Where-Object { "$($_.ReplicatedFolderName)" -like 'SYSVOL*' })
            if ($rf.Count -gt 0) {
                $k = [int]$rf[0].State
                if ($names.ContainsKey($k)) { $state = $names[$k] } else { $state = "state $k" }
            } else { $state = 'no SYSVOL folder' }
        } catch { $state = 'unavailable' }
        $shares = @(Get-SmbShare -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        $sv = $shares -contains 'SYSVOL'
        $nl = $shares -contains 'NETLOGON'
        $svc = Get-Service -Name DFSR -ErrorAction SilentlyContinue
        $svcText = 'not found'
        if ($svc) { $svcText = "$($svc.Status)" }
        [pscustomobject]@{
            sysvol_state = $state; sysvol_share = $sv; netlogon_share = $nl; dfsr_service = $svcText
            healthy = (($state -eq 'Normal') -and $sv -and $nl -and ($svcText -eq 'Running'))
        }
    }
    @{ items = @($fan.items | Select-Object -First 500); errors = $fan.errors; summary = @{ total = @($fan.items).Count; truncated = (@($fan.items).Count -gt 500); dcs = $dcs.Count; dcs_ok = $fan.summary.ok; dcs_failed = $fan.summary.failed } }
}
