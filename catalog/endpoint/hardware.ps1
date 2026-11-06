<# hermes-catalog
id: endpoint.hardware
title: Hardware summary
category: Endpoint health
description: Make, model, serial number, BIOS version, CPU and installed memory.
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, manufacturer, model, serial, bios, cpu, cores, ram_gb]
tags: [hardware, model, serial, bios, cpu, ram, inventory]
source: In-box CIM (Win32_ComputerSystem, Win32_BIOS, Win32_Processor)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $cs = Get-CimInstance Win32_ComputerSystem
        $bios = Get-CimInstance Win32_BIOS
        $cpus = @(Get-CimInstance Win32_Processor)
        [pscustomobject]@{ manufacturer = "$($cs.Manufacturer)"; model = "$($cs.Model)"; serial = "$($bios.SerialNumber)"
                           bios = "$($bios.SMBIOSBIOSVersion)"; cpu = "$($cpus[0].Name)".Trim()
                           cores = [int](($cpus | Measure-Object NumberOfCores -Sum).Sum)
                           ram_gb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1) }
    }
}
