<# hermes-catalog
id: network.wifi_profiles
title: Saved Wi-Fi profiles
category: Network
description: Names of the Wi-Fi networks saved on each computer. Names only; keys and passwords are never read. Computers without a WLAN adapter return no rows.
module: inbox:netsh
target: endpoint
tier: R
columns: [host, profile]
tags: [wifi, wireless, wlan, profiles, ssid, netsh]
source: In-box netsh wlan show profiles
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        # netsh prints an error (or nothing useful) when there is no WLAN service; that means zero rows.
        $lines = @(& { $ErrorActionPreference = 'Continue'; netsh wlan show profiles 2>$null })
        $seen = @{}
        foreach ($line in $lines) {
            if ("$line" -match '^\s*(?:All User|User) Profile\s*:\s*(.+?)\s*$') {
                $name = $Matches[1]
                if (-not $seen.ContainsKey($name) -and $seen.Count -lt 200) { $seen[$name] = $true; [pscustomobject]@{ profile = $name } }
            }
        }
    }
}
