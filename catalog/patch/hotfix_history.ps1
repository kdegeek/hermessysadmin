<# hermes-catalog
id: patch.hotfix_history
title: Installed hotfix history
category: Patching
description: Hotfixes and updates installed within the last N days, newest first.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, kb, description, installed_on, installed_by]
tags: [hotfix, kb, patches, updates, installed, history, patch level]
source: In-box Get-HotFix
params:
  - {name: Days, type: integer, default: 90, minimum: 1, maximum: 3650, description: Only list hotfixes installed within this many days.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$Days = 90)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Days) -Script {
        param($days)
        $ErrorActionPreference = 'Stop'
        $cutoff = (Get-Date).AddDays(-$days)
        @(Get-HotFix | Where-Object { $_.InstalledOn -and ([datetime]$_.InstalledOn) -ge $cutoff } | Sort-Object { [datetime]$_.InstalledOn } -Descending | Select-Object -First 200) | ForEach-Object {
            [pscustomobject]@{ kb = "$($_.HotFixID)"; description = "$($_.Description)"; installed_on = ([datetime]$_.InstalledOn).ToString('yyyy-MM-dd'); installed_by = "$($_.InstalledBy)" }
        }
    }
}
