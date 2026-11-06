<# hermes-catalog
id: endpoint.disk_usage
title: Disk usage
category: Endpoint health
description: Free and used space per fixed drive; flags drives under MinFreePercent.
module: inbox:Storage
target: endpoint
tier: R
destructive: false
preview: none
columns: [host, drive, size_gb, free_gb, free_pct, low]
tags: [disk, storage, capacity]
source: In-box Storage module (Get-Volume)
params:
  - {name: MinFreePercent, type: integer, default: 10, minimum: 1, description: Flag drives below this.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$MinFreePercent = 10)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($MinFreePercent) -Script {
        param($min)
        Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter } | ForEach-Object {
            [pscustomobject]@{ drive = "$($_.DriveLetter):"; size_gb = [math]::Round($_.Size/1GB,1)
                               free_gb = [math]::Round($_.SizeRemaining/1GB,1)
                               free_pct = if ($_.Size) { [math]::Round(100*$_.SizeRemaining/$_.Size,1) } else { 0 }
                               low = ($_.Size -and (100*$_.SizeRemaining/$_.Size) -lt $min) } }
    }
}
