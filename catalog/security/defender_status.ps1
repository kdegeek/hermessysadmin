<# hermes-catalog
id: security.defender_status
title: Microsoft Defender status
category: Security posture
description: Real-time protection, antivirus, tamper protection, signature age and last quick scan per computer.
module: inbox:Defender
target: endpoint
tier: R
columns: [host, realtime, antivirus, tamper_protected, sig_age_days, sig_version, last_quick_scan]
tags: [defender, antivirus, av, malware, signatures, tamper, protection]
source: In-box Defender (Get-MpComputerStatus)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $s = Get-MpComputerStatus
        $scan = $null
        if ($s.QuickScanEndTime) { $scan = ([datetime]$s.QuickScanEndTime).ToUniversalTime().ToString('o') }
        [pscustomobject]@{
            realtime = [bool]$s.RealTimeProtectionEnabled; antivirus = [bool]$s.AntivirusEnabled
            tamper_protected = [bool]$s.IsTamperProtected; sig_age_days = $s.AntivirusSignatureAge
            sig_version = "$($s.AntivirusSignatureVersion)"; last_quick_scan = $scan
        }
    }
}
