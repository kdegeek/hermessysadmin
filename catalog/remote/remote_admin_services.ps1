<# hermes-catalog
id: remote.remote_admin_services
title: Remote administration services
category: Remote access
description: Installed services that allow remote administration or remote control, with state and start mode. Built-in ones are Remote Registry, WinRM, Remote Desktop, OpenSSH server, Telnet, SNMP, Routing and Remote Access and the IIS Web Management Service. Third-party remote-control tools (TeamViewer, AnyDesk, VNC variants, ScreenConnect, Splashtop) are matched by service name and display name, so treat that part as a hint. Services that are not installed are not listed.
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, service, display, state, start_mode, kind]
tags: [remote registry, winrm, rdp, ssh, sshd, telnet, snmp, teamviewer, anydesk, vnc, screenconnect, remote access, attack surface]
source: In-box CIM (Win32_Service)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $builtin = @('RemoteRegistry', 'WinRM', 'TermService', 'sshd', 'TlntSvr', 'SNMP', 'RemoteAccess', 'WMSvc')
        $third = '(?i)teamviewer|anydesk|vnc|screenconnect|splashtop'
        $rows = @()
        foreach ($s in @(Get-CimInstance Win32_Service)) {
            $kind = $null
            if ($builtin -contains "$($s.Name)") { $kind = 'built-in' }
            elseif ("$($s.Name) $($s.DisplayName)" -match $third) { $kind = 'third-party' }
            if (-not $kind) { continue }
            $rows += [pscustomobject]@{ service = "$($s.Name)"; display = "$($s.DisplayName)"; state = "$($s.State)"; start_mode = "$($s.StartMode)"; kind = $kind }
        }
        $rows | Select-Object -First 100
    }
}
