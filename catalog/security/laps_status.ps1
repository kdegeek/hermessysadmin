<# hermes-catalog
id: security.laps_status
title: LAPS configuration
category: Security posture
description: Whether Windows LAPS policy and the legacy LAPS client are present, where the password is backed up and which policy source applied. Reads configuration only, never a password.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, windows_laps, legacy_laps, backup_directory, source]
tags: [laps, local admin password, windows laps, admpwd, password rotation]
source: In-box registry (LAPS CSP, GPO and local Config keys, legacy CSE)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Continue'
        # Only configuration values are read; no password or expiry attribute is queried.
        # Precedence: CSP (Intune), then GPO, then the local Config key.
        $sources = @(
            @{ name = 'CSP';   path = 'HKLM:\SOFTWARE\Microsoft\Policies\LAPS' }
            @{ name = 'GPO';   path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\LAPS' }
            @{ name = 'local'; path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\Config' }
        )
        $applied = $null; $dir = $null; $any = $false
        foreach ($s in $sources) {
            $k = Get-ItemProperty -LiteralPath $s.path -ErrorAction SilentlyContinue
            if (-not $k) { continue }
            # The first root holding any value is the active policy; settings never merge across roots
            # and a missing BackupDirectory there means 0 (disabled).
            $vals = @($k.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })
            if ($vals.Count -eq 0) { continue }
            $any = $true; $applied = $s.name
            $dir = $(if ($null -ne $k.BackupDirectory) { [int]$k.BackupDirectory } else { 0 })
            break
        }
        $dirName = switch ($dir) { 0 { 'Disabled' } 1 { 'Entra ID' } 2 { 'Active Directory' } default { 'not set' } }
        $win = 'not configured'
        if ($any) { $win = 'configured' }
        if ($dir -eq 0) { $win = 'disabled' }
        $cse = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\GPExtensions\{D76B9641-3288-4f75-942D-087DE603E3EA}'
        $legacyPol = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft Services\AdmPwd' -ErrorAction SilentlyContinue
        $legacy = 'not installed'
        if ($cse) {
            $legacy = 'installed'
            if ($legacyPol -and $legacyPol.AdmPwdEnabled -eq 1) { $legacy = 'installed and enabled' }
        }
        [pscustomobject]@{ windows_laps = $win; legacy_laps = $legacy; backup_directory = $dirName; source = $(if ($applied) { $applied } else { 'none' }) }
    }
}
