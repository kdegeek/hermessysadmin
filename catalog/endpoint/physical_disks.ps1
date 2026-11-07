<# hermes-catalog
id: endpoint.physical_disks
title: Physical disk health
category: Endpoint health
description: Each physical disk with its model, media and bus type, size, health and operational status, plus the drive's own reliability counters (temperature, wear, uncorrected read errors, power-on hours) where the drive and driver report them. Counters are often blank on virtual disks, RAID controllers and USB drives. Windows 8 / Server 2012 or later.
module: inbox:Storage
target: endpoint
tier: R
columns: [host, disk, model, media, bus, size_gb, health, status, temp_c, wear_pct, read_errors, power_on_hours]
tags: [disk, ssd, hdd, smart, health, failing drive, wear, temperature, storage]
source: In-box Storage module (Get-PhysicalDisk, Get-StorageReliabilityCounter)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop | Select-Object -First 64)) {
            $r = $null
            try { $r = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { $r = $null }
            [pscustomobject]@{ disk = "$($d.DeviceId)"; model = "$($d.FriendlyName)"; media = "$($d.MediaType)"; bus = "$($d.BusType)"
                               size_gb = [math]::Round([double]$d.Size / 1GB, 1); health = "$($d.HealthStatus)"
                               status = (@($d.OperationalStatus) | ForEach-Object { "$_" }) -join ', '
                               temp_c = if ($r) { $r.Temperature } else { $null }
                               wear_pct = if ($r) { $r.Wear } else { $null }
                               read_errors = if ($r) { $r.ReadErrorsUncorrected } else { $null }
                               power_on_hours = if ($r) { $r.PowerOnHours } else { $null } }
        }
    }
}
