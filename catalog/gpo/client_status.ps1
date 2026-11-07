<# hermes-catalog
id: gpo.client_status
title: Group Policy client status
category: Group Policy
description: When each computer last finished computer Group Policy processing, how many hours ago that was, the AD site and computer DN the client last used for policy, and how many Group Policy errors it logged in the last 24 hours. A computer that has not processed policy for days is not getting new settings. last_computer_refresh is empty when the client has never recorded a run.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, last_computer_refresh, hours_since, site, computer_dn, errors_24h]
tags: [group policy, gpo, last refresh, gpupdate, policy applied, client, stale policy, site]
source: In-box registry (Group Policy\State\Machine and its Extension-List end time) and Get-WinEvent (Microsoft-Windows-GroupPolicy/Operational)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine'
        $state = Get-ItemProperty -LiteralPath $base -ErrorAction SilentlyContinue
        $ext = Get-ItemProperty -LiteralPath "$base\Extension-List\{00000000-0000-0000-0000-000000000000}" -ErrorAction SilentlyContinue
        $last = $null
        $hoursSince = $null
        if ($ext -and $null -ne $ext.EndTimeHi -and $null -ne $ext.EndTimeLo) {
            # REG_DWORD halves come back signed (Int32) or unsigned (beyond Int32): mask both to UInt32.
            $hi = [uint32]([int64]"$($ext.EndTimeHi)" -band 4294967295)
            $lo = [uint32]([int64]"$($ext.EndTimeLo)" -band 4294967295)
            $ft = ([int64]$hi * 4294967296) + [int64]$lo
            if ($ft -gt 0) {
                $t = [DateTime]::FromFileTimeUtc($ft)
                $last = $t.ToString('o')
                $hoursSince = [math]::Round(((Get-Date).ToUniversalTime() - $t).TotalHours, 1)
            }
        }
        $errors = 0
        try {
            $errors = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-GroupPolicy/Operational'; Level = 1, 2; StartTime = (Get-Date).AddHours(-24) } -MaxEvents 500).Count
        } catch {
            if ("$($_.FullyQualifiedErrorId)" -notlike 'NoMatching*') { $errors = $null }
        }
        [pscustomobject]@{
            last_computer_refresh = $last
            hours_since = $hoursSince
            site = $(if ($state) { "$($state.'Site-Name')" } else { $null })
            computer_dn = $(if ($state) { "$($state.'Distinguished-Name')" } else { $null })
            errors_24h = $errors
        }
    }
}
