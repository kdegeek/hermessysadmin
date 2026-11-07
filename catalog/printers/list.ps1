<# hermes-catalog
id: printers.list
title: Printers and ports
category: Printers
description: Installed printers with driver, port, the port's host address, whether they are shared and their status.
module: inbox:PrintManagement
target: endpoint
tier: R
columns: [host, name, driver, port, port_host, shared, status]
tags: [printers, print, driver, port, spooler, shared]
source: In-box Get-Printer and Get-PrinterPort
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $ports = @{}
        foreach ($p in @(Get-PrinterPort)) { $ports["$($p.Name)"] = "$($p.PrinterHostAddress)" }
        foreach ($p in @(Get-Printer | Select-Object -First 200)) {
            [pscustomobject]@{
                name = "$($p.Name)"; driver = "$($p.DriverName)"; port = "$($p.PortName)"
                port_host = $(if ($ports.ContainsKey("$($p.PortName)")) { $ports["$($p.PortName)"] } else { $null })
                shared = [bool]$p.Shared; status = "$($p.PrinterStatus)"
            }
        }
    }
}
