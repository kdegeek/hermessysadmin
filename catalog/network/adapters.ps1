<# hermes-catalog
id: network.adapters
title: Network adapter link and driver
category: Network
description: Physical network adapters with status, link speed, full duplex, MAC address and driver version, provider and date. Look for 100 Mbps or half-duplex links, Disconnected adapters and old drivers. Virtual and hidden adapters are left out.
module: inbox:NetAdapter
target: endpoint
tier: R
columns: [host, name, description, status, link_speed, full_duplex, mac, driver_version, driver_provider, driver_date]
tags: [nic, adapter, link speed, duplex, driver, network card, ethernet, wifi, mac address]
source: In-box Get-NetAdapter -Physical
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        foreach ($a in @(Get-NetAdapter -Physical | Sort-Object Name | Select-Object -First 50)) {
            $fd = $null
            if ($null -ne $a.FullDuplex) { $fd = [bool]$a.FullDuplex }
            [pscustomobject]@{
                name = "$($a.Name)"; description = "$($a.InterfaceDescription)"; status = "$($a.Status)"; link_speed = "$($a.LinkSpeed)"
                full_duplex = $fd; mac = "$($a.MacAddress)"; driver_version = "$($a.DriverVersion)"; driver_provider = "$($a.DriverProvider)"
                driver_date = "$($a.DriverDate)"
            }
        }
    }
}
