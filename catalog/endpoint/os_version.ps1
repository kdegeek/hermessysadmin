<# hermes-catalog
id: endpoint.os_version
title: Windows version and build
category: Endpoint health
description: Windows edition, feature version (for example 23H2), build and update revision (UBR), architecture and the original install date. Feature updates reset the install date to the day the update was applied.
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, os, edition, version, build, ubr, arch, installed, install_days]
tags: [os, windows version, build, ubr, edition, feature update, install date, winver]
source: In-box CIM (Win32_OperatingSystem) and the HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion registry key
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $os = Get-CimInstance Win32_OperatingSystem
        $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        $version = ''; $edition = ''; $ubr = $null
        if ($cv) {
            if ($cv.DisplayVersion) { $version = "$($cv.DisplayVersion)" } elseif ($cv.ReleaseId) { $version = "$($cv.ReleaseId)" }
            $edition = "$($cv.EditionID)"
            if ($null -ne $cv.UBR) { $ubr = [int]$cv.UBR }
        }
        $installed = $null; $days = $null
        if ($os.InstallDate) {
            $installed = $os.InstallDate.ToUniversalTime().ToString('o')
            $days = [int]((Get-Date) - $os.InstallDate).TotalDays
        }
        [pscustomobject]@{ os = "$($os.Caption)"; edition = $edition; version = $version; build = "$($os.BuildNumber)"
                           ubr = $ubr; arch = "$($os.OSArchitecture)"; installed = $installed; install_days = $days }
    }
}
