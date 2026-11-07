<# hermes-catalog
id: endpoint.reliability
title: Reliability history summary
category: Endpoint health
description: Reliability Monitor data for the window - the latest and lowest stability index (1 to 10), how many reliability records were logged, how many were application or Windows failures, and the products with the most records. available is false where reliability data is not collected (the RacTask is disabled by default on Windows Server).
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, available, stability_index, lowest_index, records, app_failures, windows_failures, top_products]
tags: [reliability, stability index, reliability monitor, crashes, failures, perfmon /rel]
source: In-box CIM (Win32_ReliabilityStabilityMetrics, Win32_ReliabilityRecords)
params:
  - {name: Days, type: integer, default: 30, minimum: 1, maximum: 90, description: How many days back to summarise.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$Days = 30)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Days) -Script {
        param($days)
        $since = [Management.ManagementDateTimeConverter]::ToDmtfDateTime((Get-Date).AddDays(-$days))
        $metrics = @(); $records = @()
        try {
            $metrics = @(Get-CimInstance Win32_ReliabilityStabilityMetrics -Filter "TimeGenerated >= '$since'" -ErrorAction Stop)
            $records = @(Get-CimInstance Win32_ReliabilityRecords -Filter "TimeGenerated >= '$since'" -ErrorAction Stop | Select-Object -First 5000)
        } catch { $metrics = @(); $records = @() }
        if ($metrics.Count -eq 0 -and $records.Count -eq 0) {
            return [pscustomobject]@{ available = $false; stability_index = $null; lowest_index = $null; records = 0; app_failures = 0; windows_failures = 0; top_products = '' }
        }
        $latest = $metrics | Sort-Object TimeGenerated -Descending | Select-Object -First 1
        $lowest = $metrics | Sort-Object SystemStabilityIndex | Select-Object -First 1
        $app = @($records | Where-Object { $_.SourceName -eq 'Application Error' -or $_.SourceName -eq 'Application Hang' }).Count
        $win = @($records | Where-Object { $_.SourceName -match 'WER-SystemErrorReporting' -or ($_.SourceName -eq 'EventLog' -and $_.EventIdentifier -eq 6008) }).Count
        $topProducts = @($records | Where-Object { $_.ProductName } | Group-Object ProductName | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Name) ($($_.Count))" }) -join '; '
        [pscustomobject]@{ available = $true
                           stability_index = if ($latest) { [math]::Round([double]$latest.SystemStabilityIndex, 2) } else { $null }
                           lowest_index = if ($lowest) { [math]::Round([double]$lowest.SystemStabilityIndex, 2) } else { $null }
                           records = $records.Count; app_failures = $app; windows_failures = $win; top_products = $topProducts }
    }
}
