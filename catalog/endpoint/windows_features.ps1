<# hermes-catalog
id: endpoint.windows_features
title: Installed roles and optional features
category: Endpoint health
description: Installed server roles, role services and features on Windows Server (from Get-WindowsFeature), or enabled Windows optional features on client Windows. Optionally filtered by name. At most 500 rows per computer.
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, kind, name, display]
tags: [roles, features, optional features, server roles, iis, hyper-v, smb1, rsat, installed features]
source: In-box Get-WindowsFeature (ServerManager, servers) and CIM Win32_OptionalFeature (clients)
params:
  - {name: Name, type: string, default: '', description: Only features whose name or display name contains this text (letters digits spaces and . _ -).}
#>
param([string[]]$Computers = @(), [string]$Ou, [string]$Name = '')
Invoke-Op {
    if ($null -eq $Name) { $Name = '' }
    if ($Name -cnotmatch '\A[A-Za-z0-9 ._-]{0,100}\z') { throw "InvalidArguments: Name may only contain letters, digits, spaces, '.', '_' or '-' (up to 100 characters)" }
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Name) -Script {
        param($filter)
        $match = { param($a, $b) -not $filter -or "$a".IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or "$b".IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
        $isServer = ((Get-CimInstance Win32_OperatingSystem).ProductType -ne 1)
        $rows = @()
        if ($isServer -and (Get-Command -Name Get-WindowsFeature -ErrorAction SilentlyContinue)) {
            $rows = @(Get-WindowsFeature -ErrorAction Stop | Where-Object { $_.Installed } | ForEach-Object {
                [pscustomobject]@{ kind = "$($_.FeatureType)"; name = "$($_.Name)"; display = "$($_.DisplayName)" } })
        } else {
            $rows = @(Get-CimInstance Win32_OptionalFeature -Filter 'InstallState = 1' -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ kind = 'Optional feature'; name = "$($_.Name)"; display = "$($_.Caption)" } })
        }
        $rows | Where-Object { & $match $_.name $_.display } | Sort-Object kind, name | Select-Object -First 500
    }
}
