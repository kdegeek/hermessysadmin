<# hermes-catalog
id: security.bitlocker_status
title: BitLocker status
category: Security posture
description: BitLocker protection state, conversion progress and encryption method for each fixed volume. Never reads recovery keys or protectors.
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, drive, protection, conversion_pct, method]
tags: [bitlocker, encryption, drive, disk encryption, volume]
source: In-box CIM (Win32_EncryptableVolume)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        # Only the status methods are called; no key protector or recovery password method is used.
        $fixed = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { $_.DeviceID })
        $methods = @{ 0 = 'None'; 1 = 'AES-128 Diffuser'; 2 = 'AES-256 Diffuser'; 3 = 'AES-128'; 4 = 'AES-256'; 5 = 'Hardware'; 6 = 'XTS-AES-128'; 7 = 'XTS-AES-256' }
        $prot = @{ 0 = 'Off'; 1 = 'On'; 2 = 'Unknown' }
        foreach ($v in @(Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume)) {
            if ($fixed -notcontains $v.DriveLetter) { continue }
            $conv = Invoke-CimMethod -InputObject $v -MethodName GetConversionStatus
            $enc = Invoke-CimMethod -InputObject $v -MethodName GetEncryptionMethod
            $m = [int]$enc.EncryptionMethod
            $p = [int]$v.ProtectionStatus
            [pscustomobject]@{
                drive = "$($v.DriveLetter)"
                protection = $(if ($prot.ContainsKey($p)) { $prot[$p] } else { "$p" })
                conversion_pct = $conv.EncryptionPercentage
                method = $(if ($methods.ContainsKey($m)) { $methods[$m] } else { "$m" })
            }
        }
    }
}
