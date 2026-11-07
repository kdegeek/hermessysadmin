<# hermes-catalog
id: security.disable_smb1_server
title: Turn off the SMB1 server protocol
category: Security posture
description: Turns off the SMB1 server protocol (Set-SmbServerConfiguration -EnableSMB1Protocol $false). Takes effect without a restart; SMB2 and SMB3 clients are not affected. Undo with Set-SmbServerConfiguration -EnableSMB1Protocol $true. Refuses a computer that still has SMB1 sessions connected, or that recorded any SMB1 access in the Microsoft-Windows-SMBServer/Audit log (event 3000) in the last 30 days (those clients would lose access; the row names them), and refuses domain controllers, where an SMB1-only device would lose SYSVOL and NETLOGON domain-wide; change DCs through Group Policy after checking the SMB1 access audit. When SMB1 access auditing (AuditSmb1Access) is off, the change is still allowed but the preview says plainly that intermittent SMB1 clients such as scanners or old backup jobs cannot be detected. Does not remove the SMB1 optional feature.
module: inbox:SmbShare
target: endpoint
tier: W
preview: plan
columns: [host, before, after, smb1_sessions, smb1_audit, smb1_audit_events, result]
tags: [smb1, smbv1, disable smb1, hardening, eternalblue, legacy protocol]
source: In-box SmbShare (Get-SmbServerConfiguration, Get-SmbSession, Set-SmbServerConfiguration), Get-WinEvent (Microsoft-Windows-SMBServer/Audit event 3000) and CIM (Win32_ComputerSystem)
#>
param([string[]]$Computers = @(), [string]$Ou, [switch]$Preview)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    $work = {
        param($apply)
        $ErrorActionPreference = 'Stop'
        $role = [int](Get-CimInstance Win32_ComputerSystem).DomainRole
        $cfg = Get-SmbServerConfiguration
        $before = [bool]$cfg.EnableSMB1Protocol
        $audit = $(if ([bool]$cfg.AuditSmb1Access) { 'on' } else { 'off' })
        # SMB1 accesses recorded in the last 30 days (only logged while AuditSmb1Access is on).
        $ev = @(); $evErr = $null
        try {
            $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-SMBServer/Audit'; Id = 3000; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 1000 -ErrorAction Stop)
        } catch {
            if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { $evErr = "$($_.Exception.Message)" }
        }
        $evClients = (@($ev | ForEach-Object { $c = ''; if ($_.Properties.Count -gt 0) { $c = "$($_.Properties[0].Value)" }; if (-not $c) { $c = 'unknown client' }; $c } | Sort-Object -Unique | Select-Object -First 10) -join ', ')
        $warn = ''
        if ($audit -ne 'on') { $warn = "; warning: SMB1 access auditing is $audit, so intermittent SMB1 clients (scanners, old NAS or backup jobs) cannot be detected and may lose access" }
        $s1 = @(Get-SmbSession -ErrorAction SilentlyContinue | Where-Object { "$($_.Dialect)" -like '1.*' })
        $clients = (@($s1 | ForEach-Object { "$($_.ClientComputerName)" } | Sort-Object -Unique | Select-Object -First 5) -join ', ')
        $after = $before
        if (-not $before) { $result = 'already off' }
        elseif ($role -ge 4) { $result = 'refused: domain controller (use Group Policy after auditing SMB1 clients)' }
        elseif ($s1.Count -gt 0) { $result = "refused: $($s1.Count) SMB1 session(s) connected from $clients" }
        elseif ($evErr) { $result = "refused: could not read the SMB1 access audit log ($evErr)" }
        elseif ($ev.Count -gt 0) { $result = "refused: $($ev.Count) SMB1 access event(s) in the last 30 days from $evClients" }
        elseif (-not $apply) { $result = "will turn SMB1 server off$warn" }
        else {
            Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -Confirm:$false
            $after = [bool](Get-SmbServerConfiguration).EnableSMB1Protocol
            $result = $(if ($after) { 'still on after the change' } else { "turned off$warn" })
        }
        [pscustomobject]@{ before = $before; after = $after; smb1_sessions = $s1.Count; smb1_audit = $audit; smb1_audit_events = $ev.Count; result = $result }
    }
    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($false) -Script $work
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = @{ smb1_server = $r['before']; smb1_sessions = $r['smb1_sessions']; smb1_audit = $r['smb1_audit']; smb1_audit_events = $r['smb1_audit_events'] } }
        return @{ summary = "Turn off the SMB1 server protocol on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { "$($_['host']): $($_['result'])" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($true) -Script $work
}
