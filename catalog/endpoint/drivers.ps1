<# hermes-catalog
id: endpoint.drivers
title: Driver inventory
category: Endpoint health
description: Installed device drivers with provider, version, driver date, signer and INF, oldest first so outdated drivers stand out. Microsoft-provided drivers are left out unless IncludeMicrosoft is set. At most 200 rows per computer.
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, device, class, provider, version, date, signed, inf]
tags: [driver, drivers, driver version, outdated driver, inf, signed, oem]
source: In-box CIM (Win32_PnPSignedDriver)
params:
  - {name: Name, type: string, default: '', description: Only devices whose name contains this text (letters digits spaces and . _ - ( ) & +).}
  - {name: IncludeMicrosoft, type: boolean, default: false, description: Also list drivers whose provider is Microsoft.}
#>
param([string[]]$Computers = @(), [string]$Ou, [string]$Name = '', [bool]$IncludeMicrosoft = $false)
Invoke-Op {
    if ($null -eq $Name) { $Name = '' }
    if ($Name -cnotmatch '\A[A-Za-z0-9 ._()&+-]{0,100}\z') { throw "InvalidArguments: Name may only contain letters, digits, spaces and . _ - ( ) & + (up to 100 characters)" }
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Name, $IncludeMicrosoft) -Script {
        param($name, $includeMs)
        Get-CimInstance Win32_PnPSignedDriver |
            Where-Object { $_.DeviceName -and $_.DriverVersion } |
            Where-Object { $includeMs -or "$($_.DriverProviderName)" -ne 'Microsoft' } |
            Where-Object { -not $name -or "$($_.DeviceName)".IndexOf($name, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
            Sort-Object DriverDate | Select-Object -First 200 | ForEach-Object {
                [pscustomobject]@{ device = "$($_.DeviceName)"; class = "$($_.DeviceClass)"; provider = "$($_.DriverProviderName)"
                                   version = "$($_.DriverVersion)"
                                   date = if ($_.DriverDate) { ([datetime]$_.DriverDate).ToString('yyyy-MM-dd') } else { '' }
                                   signed = [bool]$_.IsSigned; inf = "$($_.InfName)" }
            }
    }
}
