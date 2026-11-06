<# hermes-catalog
id: security.laps_status
title: LAPS configuration
category: Security posture
description: Whether Windows LAPS policy and the legacy LAPS client are present and where the password is backed up. Reads configuration only, never a password.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, windows_laps, legacy_laps, backup_directory]
tags: [laps, local admin password, windows laps, admpwd, password rotation]
source: In-box registry (LAPS policy and CSE keys)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Continue'
        # Only configuration values are read; no password or expiry attribute is queried.
        $pol = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Policies\LAPS' -ErrorAction SilentlyContinue
        $cfg = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\Config' -ErrorAction SilentlyContinue
        $dir = $null
        if ($pol -and $null -ne $pol.BackupDirectory) { $dir = [int]$pol.BackupDirectory }
        elseif ($cfg -and $null -ne $cfg.BackupDirectory) { $dir = [int]$cfg.BackupDirectory }
        $dirName = switch ($dir) { 0 { 'Disabled' } 1 { 'Entra ID' } 2 { 'Active Directory' } default { 'not set' } }
        $win = if ($pol -or $cfg) { 'configured' } else { 'not configured' }
        $cse = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\GPExtensions\{D76B9641-3288-4f75-942D-087DE603E3EA}'
        $legacyPol = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft Services\AdmPwd' -ErrorAction SilentlyContinue
        $legacy = 'not installed'
        if ($cse) {
            $legacy = 'installed'
            if ($legacyPol -and $legacyPol.AdmPwdEnabled -eq 1) { $legacy = 'installed and enabled' }
        }
        [pscustomobject]@{ windows_laps = $win; legacy_laps = $legacy; backup_directory = $dirName }
    }
}
