<# hermes-catalog
id: endpoint.installed_software
title: Installed software
category: Endpoint health
description: Installed programs from both the 64-bit and 32-bit uninstall registry hives, optionally filtered by name.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, name, version, publisher, installed]
tags: [software, apps, programs, installed, inventory]
source: In-box registry (Uninstall keys)
params:
  - {name: Filter, type: string, description: Only programs whose name contains this text (case-insensitive).}
#>
param([string[]]$Computers = @(), [string]$Ou, [string]$Filter)
Invoke-Op {
    if ($Filter -and ($Filter.Length -gt 100 -or $Filter -match '[\r\n]')) { throw "Filter must be a single line of at most 100 characters" }
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @("$Filter") -Script {
        param($filter)
        $paths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and (-not $_.SystemComponent) -and ((-not $filter) -or $_.DisplayName.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0) } |
            Sort-Object DisplayName, DisplayVersion -Unique | Select-Object -First 200 | ForEach-Object {
                $d = "$($_.InstallDate)"
                $iso = if ($d -match '^(\d{4})(\d{2})(\d{2})$') { "$($Matches[1])-$($Matches[2])-$($Matches[3])" } else { '' }
                [pscustomobject]@{ name = "$($_.DisplayName)"; version = "$($_.DisplayVersion)"; publisher = "$($_.Publisher)"; installed = $iso }
            }
    }
}
