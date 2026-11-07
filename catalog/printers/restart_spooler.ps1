<# hermes-catalog
id: printers.restart_spooler
title: Restart the print spooler
category: Printers
description: Restarts the Print Spooler service on each computer. Queued jobs may be lost; the preview shows how many are queued.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: W
preview: plan
columns: [host, queued_jobs, status]
tags: [printers, spooler, restart, print, service]
source: In-box Restart-Service Spooler
#>
param([string[]]$Computers = @(), [string]$Ou, [switch]$Preview)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers $targets -Script {
            $ErrorActionPreference = 'Stop'
            $n = 0
            foreach ($p in @(Get-Printer)) { $n += @(Get-PrintJob -PrinterName $p.Name).Count }
            [pscustomobject]@{ queued_jobs = $n; status = "$((Get-Service -Name Spooler).Status)" }
        }
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = @{ queued_jobs = $r['queued_jobs']; status = $r['status'] } }
        return @{ summary = "Restart the Print Spooler on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { "$($_['host']): restart Spooler ($($_['queued_jobs']) queued job(s), now $($_['status']))" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $n = 0
        foreach ($p in @(Get-Printer)) { $n += @(Get-PrintJob -PrinterName $p.Name).Count }
        Restart-Service -Name Spooler -Force
        [pscustomobject]@{ queued_jobs = $n; status = "$((Get-Service -Name Spooler).Status)" }
    }
}
