<# hermes-catalog
id: sessions.user_profiles
title: User profiles
category: Users & sessions
description: Local user profiles with last use and size on disk; MinDaysUnused finds stale profiles. Size is blank for profiles not measured before the time budget ran out.
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, user, last_use, size_mb]
tags: [profiles, stale, disk, users, cleanup]
source: In-box CIM (Win32_UserProfile)
params:
  - {name: MinDaysUnused, type: integer, default: 0, minimum: 0, maximum: 3650, description: Only profiles unused for at least this many days.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$MinDaysUnused = 0)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($MinDaysUnused) -Script {
        param($minDays)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $cutoff = (Get-Date).AddDays(-$minDays)
        Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.LocalPath } |
            Where-Object { $minDays -le 0 -or -not $_.LastUseTime -or $_.LastUseTime -lt $cutoff } |
            Select-Object -First 200 | ForEach-Object {
                $user = try { ([Security.Principal.SecurityIdentifier]$_.SID).Translate([Security.Principal.NTAccount]).Value } catch { "$($_.SID)" }
                $size = $null
                if ($clock.Elapsed.TotalSeconds -lt 45 -and (Test-Path -LiteralPath $_.LocalPath)) {
                    $sum = (Get-ChildItem -LiteralPath $_.LocalPath -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
                    $size = [math]::Round([double]$sum / 1MB, 1)
                }
                [pscustomobject]@{ user = $user
                                   last_use = if ($_.LastUseTime) { $_.LastUseTime.ToUniversalTime().ToString('o') } else { '' }
                                   size_mb = $size }
            }
    }
}
