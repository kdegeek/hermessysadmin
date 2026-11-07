<# hermes-catalog
id: endpoint.time_sync
title: Time synchronisation status
category: Endpoint health
description: Windows Time service state, configured sync type (NT5DS follows the domain hierarchy, NTP uses the listed peers), current time source, stratum, last successful sync, minutes since then and phase offset in seconds. The w32tm fields are parsed from English output and are blank on other display languages.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, service, type, peers, source, stratum, last_sync, minutes_since_sync, offset_s]
tags: [time, ntp, w32time, w32tm, clock skew, kerberos, time source, sync]
source: In-box w32tm /query /status /verbose and the W32Time\Parameters registry key
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $svc = Get-Service -Name W32Time -ErrorAction SilentlyContinue
        $par = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' -ErrorAction SilentlyContinue
        $row = [ordered]@{ service = if ($svc) { "$($svc.Status)" } else { 'NotInstalled' }
                           type = if ($par) { "$($par.Type)" } else { '' }; peers = if ($par) { "$($par.NtpServer)" } else { '' }
                           source = ''; stratum = $null; last_sync = $null; minutes_since_sync = $null; offset_s = $null }
        if ($svc -and $svc.Status -eq 'Running') {
            $ErrorActionPreference = 'Continue'
            $out = @(w32tm.exe /query /status /verbose 2>$null)
            foreach ($line in $out) {
                $l = "$line"
                if ($l -match '^\s*Source:\s*(.+?)\s*$') { $row.source = $Matches[1] }
                elseif ($l -match '^\s*Stratum:\s*(\d+)') { $row.stratum = [int]$Matches[1] }
                elseif ($l -match '^\s*Phase Offset:\s*(-?[\d.]+)s') { $row.offset_s = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) }
                elseif ($l -match '^\s*Last Successful Sync Time:\s*(.+?)\s*$') {
                    $dt = [datetime]::MinValue
                    if ([datetime]::TryParse($Matches[1], [ref]$dt)) {
                        $row.last_sync = $dt.ToUniversalTime().ToString('o')
                        $row.minutes_since_sync = [int]((Get-Date) - $dt).TotalMinutes
                    }
                }
            }
        }
        [pscustomobject]$row
    }
}
