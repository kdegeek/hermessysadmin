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
    if ($Printer -notmatch '^[^\\/:*?"<>|]{1,256}$') { throw 'InvalidArguments: Printer must be a printer name (no \ / : * ? " < > | characters, up to 256 characters)' }
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Printer) -Script {
            param($name)
            $ErrorActionPreference = 'Stop'
            foreach ($j in @(Get-PrintJob -PrinterName $name | Select-Object -First 50)) {
                [pscustomobject]@{ job = [int]$j.Id; document = "$($j.DocumentName)"; user = "$($j.UserName)" }
            }
        }
        $cur = @{}
        foreach ($r in $read.items) {
            if (-not $cur.ContainsKey($r['host'])) { $cur[$r['host']] = @() }
            $cur[$r['host']] += ,@{ job = $r['job']; document = $r['document']; user = $r['user'] }
        }
        return @{ summary = "Clear the queue of printer '$Printer' on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { "$($_['host']): remove job $($_['job']) '$($_['document'])' ($($_['user']))" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable or printer missing ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Printer) -Script {
        param($name)
        $ErrorActionPreference = 'Stop'
        $jobs = @(Get-PrintJob -PrinterName $name)
        $jobs | Remove-PrintJob
        [pscustomobject]@{ printer = $name; before = $jobs.Count; after = @(Get-PrintJob -PrinterName $name).Count }
    }
}
