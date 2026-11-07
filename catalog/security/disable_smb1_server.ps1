<# hermes-catalog
id: security.disable_smb1_server
title: Turn off the SMB1 server protocol
category: Security posture
description: Turns off the SMB1 server protocol (Set-SmbServerConfiguration -EnableSMB1Protocol $false). Takes effect without a restart; SMB2 and SMB3 clients are not affected. Undo with Set-SmbServerConfiguration -EnableSMB1Protocol $true. Refuses a computer that still has SMB1 sessions connected (those clients would lose access; the row names them) and refuses domain controllers, where an SMB1-only device would lose SYSVOL and NETLOGON domain-wide; change DCs through Group Policy after checking the SMB1 access audit. Does not remove the SMB1 optional feature.
module: inbox:SmbShare
target: endpoint
tier: W
preview: plan
columns: [host, before, after, smb1_sessions, result]
tags: [smb1, smbv1, disable smb1, hardening, eternalblue, legacy protocol]
source: In-box SmbShare (Get-SmbServerConfiguration, Get-SmbSession, Set-SmbServerConfiguration) and CIM (Win32_ComputerSystem)
#>
param([string[]]$Computers = @(), [string]$Ou, [switch]$Preview)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    $work = {
        param($apply)
        $ErrorActionPreference = 'Stop'
        $role = [int](Get-CimInstance Win32_ComputerSystem).DomainRole
        $before = [bool](Get-SmbServerConfiguration).EnableSMB1Protocol
        $s1 = @(Get-SmbSession -ErrorAction SilentlyContinue | Where-Object { "$($_.Dialect)" -like '1.*' })
        $clients = (@($s1 | ForEach-Object { "$($_.ClientComputerName)" } | Sort-Object -Unique | Select-Object -First 5) -join ', ')
        $after = $before
        if (-not $before) { $result = 'already off' }
        elseif ($role -ge 4) { $result = 'refused: domain controller (use Group Policy after auditing SMB1 clients)' }
        elseif ($s1.Count -gt 0) { $result = "refused: $($s1.Count) SMB1 session(s) connected from $clients" }
        elseif (-not $apply) { $result = 'will turn SMB1 server off' }
        else {
            Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -Confirm:$false
            $after = [bool](Get-SmbServerConfiguration).EnableSMB1Protocol
            $result = $(if ($after) { 'still on after the change' } else { 'turned off' })
        }
        [pscustomobject]@{ before = $before; after = $after; smb1_sessions = $s1.Count; result = $result }
    }
    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($false) -Script $work
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = @{ smb1_server = $r['before']; smb1_sessions = $r['smb1_sessions'] } }
        return @{ summary = "Turn off the SMB1 server protocol on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { "$($_['host']): $($_['result'])" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($true) -Script $work
}
