<# hermes-catalog
id: endpoint.top_processes
title: Top processes
category: Endpoint health
description: The busiest processes per computer by CPU time or memory. The user column is blank when the remote session is not elevated.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, name, pid, cpu_s, ws_mb, user]
tags: [process, cpu, memory, slow, performance]
source: In-box Get-Process
params:
  - {name: Top, type: integer, default: 10, minimum: 1, maximum: 50, description: How many processes to return per computer.}
  - {name: SortBy, type: string, default: cpu, enum: [cpu, memory], description: Rank by cumulative CPU time or working set memory.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$Top = 10, [string]$SortBy = 'cpu')
Invoke-Op {
    if ($SortBy -notin @('cpu', 'memory')) { throw "SortBy must be cpu or memory" }
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Top, $SortBy) -Script {
        param($top, $sort)
        $withUser = $true
        try { $procs = @(Get-Process -IncludeUserName -ErrorAction Stop) }
        catch { $withUser = $false; $procs = @(Get-Process -ErrorAction SilentlyContinue) }
        $key = if ($sort -eq 'memory') { 'WorkingSet64' } else { 'CPU' }
        $procs | Sort-Object -Property $key -Descending | Select-Object -First $top | ForEach-Object {
            [pscustomobject]@{ name = $_.ProcessName; pid = $_.Id
                               cpu_s = if ($null -ne $_.CPU) { [math]::Round([double]$_.CPU, 1) } else { 0 }
                               ws_mb = [math]::Round($_.WorkingSet64 / 1MB, 1)
                               user = if ($withUser) { "$($_.UserName)" } else { '' } }
        }
    }
}
