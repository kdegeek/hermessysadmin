<# hermes-catalog
id: printers.clear_queue
title: Clear a stuck print queue
category: Printers
description: Removes every job from one printer's queue on each computer. The jobs belong to users but are transient; the preview lists them first.
module: inbox:PrintManagement
target: endpoint
tier: W
preview: plan
destructive: false
columns: [host, printer, before, after]
tags: [printers, queue, clear, stuck, jobs, purge]
source: In-box Get-PrintJob and Remove-PrintJob
params:
  - {name: Printer, type: string, required: true, description: Name of the printer whose queue to clear.}
#>
param([string[]]$Computers = @(), [string]$Ou, [string]$Printer, [switch]$Preview)
Invoke-Op {
    if ($Printer -cnotmatch '\A[^\\/:*?"<>|\x00-\x1f]{1,256}\z') { throw 'InvalidArguments: Printer must be a printer name (no \ / : * ? " < > | characters, up to 256 characters)' }
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Printer) -Script {
            param($name)
            $ErrorActionPreference = 'Stop'
            $all = @(Get-PrintJob -PrinterName $name)
            foreach ($j in @($all | Select-Object -First 50)) {
                [pscustomobject]@{ job = [int]$j.Id; document = "$($j.DocumentName)"; user = "$($j.UserName)"; total = $all.Count }
            }
            if ($all.Count -eq 0) { [pscustomobject]@{ job = $null; document = $null; user = $null; total = 0 } }
        }
        $cur = @{}
        $totals = @{}
        foreach ($r in $read.items) {
            $totals[$r['host']] = $r['total']
            if ($null -eq $r['job']) { continue }
            if (-not $cur.ContainsKey($r['host'])) { $cur[$r['host']] = @() }
            $cur[$r['host']] += ,@{ job = $r['job']; document = $r['document']; user = $r['user'] }
        }
        return @{ summary = "Clear the queue of printer '$Printer' on $($targets.Count) computer(s)"
                  changes = @($read.items | Where-Object { $null -ne $_['job'] } | ForEach-Object { "$($_['host']): remove job $($_['job']) '$($_['document'])' ($($_['user']))" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable or printer missing ($($_.message))" })
                  current = $cur; totals = $totals }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Printer) -Script {
        param($name)
        $ErrorActionPreference = 'Stop'
        $jobs = @(Get-PrintJob -PrinterName $name)
        $jobs | Remove-PrintJob
        [pscustomobject]@{ printer = $name; before = $jobs.Count; after = @(Get-PrintJob -PrinterName $name).Count }
    }
}
