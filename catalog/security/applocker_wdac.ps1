<# hermes-catalog
id: security.applocker_wdac
title: AppLocker and WDAC posture
category: Security posture
description: Application Identity service state, effective AppLocker rule counts per collection and the user-mode code integrity (WDAC) enforcement state.
module: inbox:AppLocker
target: endpoint
tier: R
columns: [host, applocker_rules, appidsvc, wdac_user_mode]
tags: [applocker, wdac, code integrity, application control, whitelisting, device guard]
source: In-box AppLocker and CIM (Win32_DeviceGuard)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $svc = Get-Service -Name AppIDSvc -ErrorAction SilentlyContinue
        $svcText = 'not found'
        if ($svc) { $svcText = "$($svc.Status) ($($svc.StartType))" }
        $rules = 'unavailable'
        try {
            $pol = Get-AppLockerPolicy -Effective
            $parts = @(foreach ($c in @($pol.RuleCollections)) { "$($c.RuleCollectionType):$(@($c).Count)" })
            if ($parts.Count -eq 0) { $rules = 'none' } else { $rules = $parts -join ', ' }
        } catch { $rules = 'unavailable' }
        $wdac = 'unknown'
        try {
            $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard
            $wdac = switch ([int]$dg.UsermodeCodeIntegrityPolicyEnforcementStatus) { 0 { 'off' } 1 { 'audit' } 2 { 'enforced' } default { 'unknown' } }
        } catch { $wdac = 'unknown' }
        [pscustomobject]@{ applocker_rules = $rules; appidsvc = $svcText; wdac_user_mode = $wdac }
    }
}
