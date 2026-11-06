<# hermes-catalog
id: security.local_admins
title: Local administrators
category: Security posture
description: Members of the local Administrators group on each computer, found by well-known SID so it works on any language.
module: inbox:Microsoft.PowerShell.LocalAccounts
target: endpoint
tier: R
columns: [host, member, type, source]
tags: [administrators, local admin, admin group, privileged, members]
source: In-box LocalAccounts (Get-LocalGroupMember)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $rows = @()
        try {
            foreach ($m in @(Get-LocalGroupMember -SID 'S-1-5-32-544')) {
                $rows += [pscustomobject]@{ member = "$($m.Name)"; type = "$($m.ObjectClass)"; source = "$($m.PrincipalSource)" }
            }
        } catch {
            # Get-LocalGroupMember fails on orphaned domain SIDs in 5.1; fall back to ADSI by the group's translated name.
            $gn = (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544').Translate([System.Security.Principal.NTAccount]).Value.Split('\')[1]
            $g = [ADSI]"WinNT://./$gn,group"
            foreach ($mem in @($g.Invoke('Members'))) {
                $a = [ADSI]$mem
                $path = $a.Path -replace '^WinNT://', ''
                $rows += [pscustomobject]@{ member = $path.Replace('/', '\'); type = "$($a.SchemaClassName)"; source = 'ADSI' }
            }
        }
        $rows | Select-Object -First 200
    }
}
