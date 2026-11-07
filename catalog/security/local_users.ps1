<# hermes-catalog
id: security.local_users
title: Local user accounts
category: Security posture
description: Local (SAM) user accounts on each computer with enabled state, RID, last logon, when the password was last set, whether it expires and whether one is required. Never reads or returns passwords. Domain controllers have no local accounts and are reported with a note instead. At most 200 accounts per computer.
module: inbox:Microsoft.PowerShell.LocalAccounts
target: endpoint
tier: R
columns: [host, name, enabled, rid, last_logon, password_last_set, password_expires, password_required, note]
tags: [local users, local accounts, sam, accounts, stale accounts, password age, administrator, guest]
source: In-box LocalAccounts (Get-LocalUser) and CIM (Win32_ComputerSystem)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        function To-Iso($d) { if ($null -eq $d) { return $null }; return ([datetime]$d).ToUniversalTime().ToString('o') }
        if ([int](Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4) {
            return [pscustomobject]@{ name = $null; enabled = $null; rid = $null; last_logon = $null; password_last_set = $null; password_expires = $null; password_required = $null; note = 'domain controller: no local accounts' }
        }
        foreach ($u in @(Get-LocalUser | Select-Object -First 200)) {
            $rid = $null
            if ($u.SID) { $rid = [int]("$($u.SID.Value)".Split('-')[-1]) }
            [pscustomobject]@{
                name = "$($u.Name)"; enabled = [bool]$u.Enabled; rid = $rid
                last_logon = (To-Iso $u.LastLogon); password_last_set = (To-Iso $u.PasswordLastSet)
                password_expires = (To-Iso $u.PasswordExpires); password_required = [bool]$u.PasswordRequired; note = $null
            }
        }
    }
}
