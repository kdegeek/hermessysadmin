<# hermes-catalog
id: printers.ports
title: Printer ports
category: Printers
description: Printer ports with their type, the printer's host address and TCP port for network ports, whether SNMP status is on, and how many printers use each port. Ports no printer uses, or several ports pointing at the same address, are cleanup candidates. Up to 200 ports per computer.
module: inbox:PrintManagement
target: endpoint
tier: R
columns: [host, name, description, host_address, port_number, snmp, printers]
tags: [printers, ports, tcp/ip port, standard tcp port, printer ip, snmp, raw 9100, lpr]
source: In-box Get-PrinterPort and Get-Printer
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $use = @{}
        foreach ($p in @(Get-Printer)) { $k = "$($p.PortName)"; if ($use.ContainsKey($k)) { $use[$k]++ } else { $use[$k] = 1 } }
        foreach ($p in @(Get-PrinterPort | Sort-Object Name | Select-Object -First 200)) {
            $num = $null
            if ($p.PSObject.Properties['PortNumber'] -and $p.PortNumber) { $num = [int]$p.PortNumber }
            $snmp = $null
            if ($p.PSObject.Properties['SNMPEnabled'] -and $null -ne $p.SNMPEnabled) { $snmp = [bool]$p.SNMPEnabled }
            [pscustomobject]@{
                name = "$($p.Name)"; description = "$($p.Description)"
                host_address = $(if ($p.PSObject.Properties['PrinterHostAddress'] -and $p.PrinterHostAddress) { "$($p.PrinterHostAddress)" } else { $null })
                port_number = $num; snmp = $snmp
                printers = $(if ($use.ContainsKey("$($p.Name)")) { $use["$($p.Name)"] } else { 0 })
            }
        }
    }
}
