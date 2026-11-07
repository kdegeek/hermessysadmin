<# hermes-catalog
id: security.autorun_policy
title: AutoRun and AutoPlay policy
category: Security posture
description: Machine-wide AutoRun and AutoPlay policy. no_drive_type_autorun is the NoDriveTypeAutoRun bit mask (255 turns AutoPlay off on every drive type; missing means the Windows default, which leaves it on for removable drives). autorun_commands_off is true when NoAutorun is 1, so autorun.inf commands never run. Per-user policy under HKCU is not read.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, no_drive_type_autorun, autoplay_off_all_drives, autorun_commands_off, autoplay_non_volume_off]
tags: [autorun, autoplay, usb, removable media, autorun.inf, policy]
source: In-box registry (HKLM Policies\Explorer)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $e = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' -ErrorAction SilentlyContinue
        $w = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' -ErrorAction SilentlyContinue
        $mask = $null
        if ($e -and $null -ne $e.NoDriveTypeAutoRun) { $mask = [int]$e.NoDriveTypeAutoRun }
        [pscustomobject]@{
            no_drive_type_autorun   = $mask
            autoplay_off_all_drives = ($null -ne $mask -and ($mask -band 0xFF) -eq 0xFF)
            autorun_commands_off    = [bool]($e -and $null -ne $e.NoAutorun -and [int]$e.NoAutorun -eq 1)
            autoplay_non_volume_off = [bool]($w -and $null -ne $w.NoAutoplayfornonVolume -and [int]$w.NoAutoplayfornonVolume -eq 1)
        }
    }
}
