<# hermes-catalog
id: security.unquoted_service_paths
title: Unquoted service paths
category: Security posture
description: Services whose executable path contains a space and is not in quotes, so Windows may run a planted program from a parent folder (for example C:\Program.exe) as the service account. Exploiting one also needs write access to that folder, which this entry does not check. At most 200 services per computer.
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, name, display, start_mode, account, path]
tags: [services, unquoted service path, privilege escalation, service path, hardening]
source: In-box CIM (Win32_Service)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $rows = @()
        foreach ($s in @(Get-CimInstance Win32_Service)) {
            $p = "$($s.PathName)".Trim()
            if ($p -eq '' -or $p.StartsWith('"')) { continue }
            if ($p -notmatch '^(?<exe>.+?\.exe)(\s|$)') { continue }
            if ($Matches['exe'] -notmatch ' ') { continue }
            $rows += [pscustomobject]@{ name = "$($s.Name)"; display = "$($s.DisplayName)"; start_mode = "$($s.StartMode)"; account = "$($s.StartName)"; path = $p }
        }
        $rows | Select-Object -First 200
    }
}
