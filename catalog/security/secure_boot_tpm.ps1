<# hermes-catalog
id: security.secure_boot_tpm
title: Secure Boot and TPM
category: Security posture
description: Whether Secure Boot is on and whether a TPM is present and ready, with its specification version.
module: inbox:TrustedPlatformModule
target: endpoint
tier: R
columns: [host, secure_boot, tpm_present, tpm_ready, tpm_version]
tags: [secure boot, tpm, uefi, windows 11, hardware security]
source: In-box SecureBoot, TrustedPlatformModule and CIM (Win32_Tpm)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $sb = 'unsupported'
        try { $sb = $(if (Confirm-SecureBootUEFI) { 'enabled' } else { 'disabled' }) } catch { $sb = 'unsupported' }
        $present = $null; $ready = $null; $ver = $null
        try { $t = Get-Tpm; $present = [bool]$t.TpmPresent; $ready = [bool]$t.TpmReady } catch { $present = $null; $ready = $null }
        try {
            $w = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm
            if ($w -and $w.SpecVersion) { $ver = "$($w.SpecVersion)".Split(',')[0].Trim() }
        } catch { $ver = $null }
        [pscustomobject]@{ secure_boot = $sb; tpm_present = $present; tpm_ready = $ready; tpm_version = $ver }
    }
}
