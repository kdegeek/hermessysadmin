<# hermes-catalog
id: patch.patch_level
title: Cumulative update level across computers
category: Patching
description: Compares the update revision (UBR) of computers on the same Windows build to find the ones that missed a cumulative update. newest_in_result is the highest build.UBR seen among the computers checked on the same build, and behind is true for computers below it, so check a representative set of computers in one run. Also shows the newest installed hotfix and the last boot (a computer that has not restarted since its update finishes installing on the next boot). For the absolute current level compare full_build with Microsoft's release information.
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, display_version, full_build, newest_in_result, behind, last_hotfix, last_hotfix_date, last_boot]
tags: [ubr, patch level, cumulative update, missed update, behind, compliance, build, latest cu, patch tuesday]
source: In-box registry (Windows NT\CurrentVersion CurrentBuild, UBR, DisplayVersion), CIM Win32_OperatingSystem and Get-HotFix
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    $fan = Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $os = Get-CimInstance Win32_OperatingSystem
        $ubr = $null
        if ($null -ne $cv.UBR) { $ubr = [int]$cv.UBR }
        $build = "$($cv.CurrentBuild)"
        $dv = "$($cv.DisplayVersion)"
        if (-not $dv) { $dv = "$($cv.ReleaseId)" }
        $hf = $null
        try {
            $hf = @(Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object { [datetime]$_.InstalledOn } -Descending | Select-Object -First 1)
        } catch { $hf = @() }
        [pscustomobject]@{
            display_version = $dv
            build = $build
            full_build = $(if ($null -ne $ubr) { "$build.$ubr" } else { $build })
            ubr = $ubr
            last_hotfix = $(if ($hf.Count) { "$($hf[0].HotFixID)" } else { $null })
            last_hotfix_date = $(if ($hf.Count) { ([datetime]$hf[0].InstalledOn).ToString('yyyy-MM-dd') } else { $null })
            last_boot = $(if ($os.LastBootUpTime) { ([datetime]$os.LastBootUpTime).ToUniversalTime().ToString('o') } else { $null })
        }
    }
    $newest = @{}
    foreach ($r in $fan.items) {
        if ($null -eq $r['ubr']) { continue }
        $b = "$($r['build'])"
        if (-not $newest.ContainsKey($b) -or [int]$r['ubr'] -gt $newest[$b]) { $newest[$b] = [int]$r['ubr'] }
    }
    $builds = @{}
    foreach ($r in $fan.items) {
        $b = "$($r['build'])"
        $r['newest_in_result'] = $(if ($newest.ContainsKey($b)) { "$b.$($newest[$b])" } else { $null })
        $r['behind'] = ($null -ne $r['ubr'] -and $newest.ContainsKey($b) -and [int]$r['ubr'] -lt $newest[$b])
        $fb = "$($r['full_build'])"
        if ($builds.ContainsKey($fb)) { $builds[$fb]++ } else { $builds[$fb] = 1 }
    }
    $fan.summary['builds'] = $builds
    $fan.summary['behind'] = @($fan.items | Where-Object { $_['behind'] }).Count
    $fan
}
