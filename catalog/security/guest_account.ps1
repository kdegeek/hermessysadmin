<# hermes-catalog
id: security.guest_account
title: Guest account state
category: Security posture
description: Name and enabled state of the built-in Guest account (RID 501) on each computer.
module: inbox:Microsoft.PowerShell.LocalAccounts
target: endpoint
tier: R
columns: [host, name, enabled]
tags: [guest, built-in account, local user, rid 501]
source: In-box LocalAccounts (Get-LocalUser)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        foreach ($u in @(Get-LocalUser | Where-Object { $_.SID.Value -like '*-501' })) {
            [pscustomobject]@{ name = "$($u.Name)"; enabled = [bool]$u.Enabled }
        }
    }
}
