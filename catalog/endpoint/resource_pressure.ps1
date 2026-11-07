<# hermes-catalog
id: endpoint.resource_pressure
title: CPU and memory pressure now
category: Endpoint health
description: A point-in-time view of CPU load, processor queue length, physical memory use, commit charge and hard page faults per second. pressure is true when CPU, memory or commit use is at or above 90 percent. CPU load is the processor's own short average and can be blank on some virtual machines.
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, cpu_pct, cpu_queue, mem_total_gb, mem_free_gb, mem_used_pct, commit_pct, pages_sec, pressure]
tags: [cpu, memory, ram, performance, slow, load, commit, paging, pressure]
source: In-box CIM (Win32_Processor, Win32_OperatingSystem, Win32_PerfFormattedData_PerfOS_System and Win32_PerfFormattedData_PerfOS_Memory)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $os = Get-CimInstance Win32_OperatingSystem
        $loads = @(Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Where-Object { $null -ne $_.LoadPercentage } | ForEach-Object { [double]$_.LoadPercentage })
        $cpu = $null
        if ($loads.Count) { $cpu = [math]::Round(($loads | Measure-Object -Average).Average, 1) }
        $sys = Get-CimInstance Win32_PerfFormattedData_PerfOS_System -ErrorAction SilentlyContinue | Select-Object -First 1
        $mem = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction SilentlyContinue | Select-Object -First 1
        $totalKb = [double]$os.TotalVisibleMemorySize
        $freeKb = [double]$os.FreePhysicalMemory
        $used = $null
        if ($totalKb -gt 0) { $used = [math]::Round(100 * ($totalKb - $freeKb) / $totalKb, 1) }
        $commit = $null; $pages = $null; $queue = $null
        if ($mem) { $commit = [double]$mem.PercentCommittedBytesInUse; $pages = [double]$mem.PagesPersec }
        if ($sys) { $queue = [int]$sys.ProcessorQueueLength }
        [pscustomobject]@{ cpu_pct = $cpu; cpu_queue = $queue
                           mem_total_gb = [math]::Round($totalKb / 1MB, 1); mem_free_gb = [math]::Round($freeKb / 1MB, 1)
                           mem_used_pct = $used; commit_pct = $commit; pages_sec = $pages
                           pressure = (($cpu -ge 90) -or ($used -ge 90) -or ($commit -ge 90)) }
    }
}
