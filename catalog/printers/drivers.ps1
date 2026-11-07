<# hermes-catalog
id: printers.drivers
title: Printer drivers
category: Printers
description: Installed printer drivers with the driver model (Type 3 classic or Type 4 class driver), version, manufacturer, platform and how many installed printers use each. Unused or old Type 3 drivers are the ones worth cleaning up. Up to 200 drivers per computer.
module: inbox:PrintManagement
target: endpoint
tier: R
columns: [host, name, type, version, manufacturer, environment, printers]
tags: [printers, drivers, printer driver, type 3, type 4, v3, v4, driver version, print server]
source: In-box Get-PrinterDriver and Get-Printer
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $use = @{}
        foreach ($p in @(Get-Printer)) { $k = "$($p.DriverName)"; if ($use.ContainsKey($k)) { $use[$k]++ } else { $use[$k] = 1 } }
        foreach ($d in @(Get-PrinterDriver | Sort-Object Name | Select-Object -First 200)) {
            $ver = $null
            if ($d.DriverVersion) {
                $v = [uint64]$d.DriverVersion
                $ver = '{0}.{1}.{2}.{3}' -f (($v -shr 48) -band 0xffff), (($v -shr 32) -band 0xffff), (($v -shr 16) -band 0xffff), ($v -band 0xffff)
            }
            [pscustomobject]@{
                name = "$($d.Name)"; type = $(if ($d.MajorVersion) { "Type $([int]$d.MajorVersion)" } else { $null }); version = $ver
                manufacturer = "$($d.Manufacturer)"; environment = "$($d.PrinterEnvironment)"
                printers = $(if ($use.ContainsKey("$($d.Name)")) { $use["$($d.Name)"] } else { 0 })
            }
        }
    }
}
