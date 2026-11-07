<# hermes-catalog
id: network.mapped_drives
title: Mapped network drives
category: Network
description: Persistent mapped network drives of the users whose profile is loaded on each computer (normally the signed-in users), with the drive letter and UNC path. Drives mapped without persistence (some logon scripts) are not stored and do not show. Stored alternate credentials are never read.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, user, drive, remote_path]
tags: [mapped drives, network drives, net use, unc, drive letter, shares, logon script]
source: In-box registry (HKEY_USERS\<SID>\Network for loaded user hives)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $n = 0
        foreach ($hive in @(Get-ChildItem -Path 'Registry::HKEY_USERS' | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' })) {
            $sid = $hive.PSChildName
            $user = $sid
            try { $user = (New-Object System.Security.Principal.SecurityIdentifier $sid).Translate([System.Security.Principal.NTAccount]).Value } catch { $user = $sid }
            $net = "Registry::HKEY_USERS\$sid\Network"
            if (-not (Test-Path -LiteralPath $net)) { continue }
            foreach ($d in @(Get-ChildItem -LiteralPath $net)) {
                if ($n -ge 200) { return }
                $n++
                $remote = $null
                try { $remote = (Get-ItemProperty -LiteralPath $d.PSPath -Name RemotePath -ErrorAction Stop).RemotePath } catch { $remote = $null }
                [pscustomobject]@{ user = $user; drive = "$($d.PSChildName.ToUpperInvariant()):"; remote_path = "$remote" }
            }
        }
    }
}
