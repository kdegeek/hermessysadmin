<# hermes-catalog
id: endpoint.activation
title: Windows activation status
category: Endpoint health
description: Windows licence status per computer - product name, licensing channel (Retail, OEM, Volume KMS or MAK), status (Licensed, grace periods, Notification), days of grace left and the KMS host it last found. No product key or partial key is returned. The licensing query can take several seconds per computer.
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, product, channel, status, licensed, grace_days, kms_host]
tags: [activation, licence, license, kms, mak, slmgr, genuine, not activated]
source: In-box CIM (SoftwareLicensingProduct)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $status = @{ 0 = 'Unlicensed'; 1 = 'Licensed'; 2 = 'OOBGrace'; 3 = 'OOTGrace'; 4 = 'NonGenuineGrace'; 5 = 'Notification'; 6 = 'ExtendedGrace' }
        # Windows application id; only installed (keyed) SKUs. The key fields are used in the filter but never selected.
        $q = "SELECT Name, Description, LicenseStatus, GracePeriodRemaining, DiscoveredKeyManagementServiceMachineName FROM SoftwareLicensingProduct WHERE ApplicationID = '55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL"
        foreach ($p in @(Get-CimInstance -Query $q -ErrorAction Stop)) {
            $code = [int]$p.LicenseStatus
            $channel = ''
            if ("$($p.Description)" -match ',\s*(\S+)\s+channel') { $channel = $Matches[1] }
            [pscustomobject]@{ product = "$($p.Name)"; channel = $channel
                               status = if ($status.ContainsKey($code)) { $status[$code] } else { "Unknown ($code)" }
                               licensed = ($code -eq 1)
                               grace_days = if ($code -ne 1 -and $p.GracePeriodRemaining) { [math]::Round([double]$p.GracePeriodRemaining / 1440, 1) } else { $null }
                               kms_host = "$($p.DiscoveredKeyManagementServiceMachineName)" }
        }
    }
}
