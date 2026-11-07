<# hermes-catalog
id: endpoint.problem_devices
title: Devices with problems
category: Endpoint health
description: Plug and Play devices that Device Manager would flag (ConfigManagerErrorCode not 0), with the error code and its meaning, such as missing drivers (28), failed to start (10) or disabled (22). Code 45 (device not currently connected) is left out unless IncludeDisconnected is set.
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, name, class, code, meaning, device_id]
tags: [device manager, driver, yellow bang, unknown device, pnp, hardware error, code 28, code 10]
source: In-box CIM (Win32_PnPEntity)
params:
  - {name: IncludeDisconnected, type: boolean, default: false, description: Also list devices that are only absent (code 45).}
#>
param([string[]]$Computers = @(), [string]$Ou, [bool]$IncludeDisconnected = $false)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($IncludeDisconnected) -Script {
        param($includeDisconnected)
        $meaning = @{ 1 = 'not configured correctly'; 3 = 'driver corrupt or low memory'; 10 = 'cannot start'; 12 = 'not enough free resources'
                      14 = 'restart required'; 18 = 'drivers need reinstalling'; 19 = 'registry configuration damaged'; 21 = 'being removed'
                      22 = 'disabled'; 24 = 'not present or not all drivers installed'; 28 = 'drivers not installed'; 29 = 'disabled by firmware'
                      31 = 'driver could not load'; 32 = 'driver service disabled'; 37 = 'driver failed to initialise'; 39 = 'driver missing or corrupt'
                      43 = 'stopped after reporting problems'; 45 = 'not currently connected'; 48 = 'driver blocked'; 52 = 'driver signature not verified' }
        Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' |
            Where-Object { $includeDisconnected -or $_.ConfigManagerErrorCode -ne 45 } | Select-Object -First 200 | ForEach-Object {
                $code = [int]$_.ConfigManagerErrorCode
                [pscustomobject]@{ name = "$($_.Name)"; class = "$($_.PNPClass)"; code = $code
                                   meaning = if ($meaning.ContainsKey($code)) { $meaning[$code] } else { 'see Device Manager' }
                                   device_id = "$($_.PNPDeviceID)" }
            }
    }
}
