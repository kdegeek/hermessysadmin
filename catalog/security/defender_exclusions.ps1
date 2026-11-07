<# hermes-catalog
id: security.defender_exclusions
title: Microsoft Defender exclusions
category: Security posture
description: Defender antivirus exclusions on each computer, one row per excluded path, extension, process or IP address, from local settings and policy. Attackers add exclusions to hide malware, so unexpected entries matter. A computer with none returns a single row with kind none. At most 200 rows per computer. Fails on computers where Defender is not the active antivirus.
module: inbox:Defender
target: endpoint
tier: R
columns: [host, kind, value]
tags: [defender, exclusions, antivirus, exclusion path, exclusion process, av bypass, tamper]
source: In-box Defender (Get-MpPreference)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $p = Get-MpPreference
        $rows = @()
        foreach ($pair in @(@('path', $p.ExclusionPath), @('extension', $p.ExclusionExtension), @('process', $p.ExclusionProcess), @('ip address', $p.ExclusionIpAddress))) {
            foreach ($v in @($pair[1])) {
                if ($null -eq $v -or "$v".Trim() -eq '') { continue }
                $rows += [pscustomobject]@{ kind = $pair[0]; value = "$v" }
            }
        }
        if ($rows.Count -eq 0) { $rows += [pscustomobject]@{ kind = 'none'; value = $null } }
        $rows | Select-Object -First 200
    }
}
