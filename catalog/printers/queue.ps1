<# hermes-catalog
id: printers.queue
title: Print queue jobs
category: Printers
description: Jobs waiting in each printer queue with document name, owner, status, page count and submit time.
module: inbox:PrintManagement
target: endpoint
tier: R
columns: [host, printer, id, document, user, status, pages, submitted]
tags: [printers, queue, jobs, stuck, spooler, print jobs]
source: In-box Get-PrintJob
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $rows = @()
        foreach ($p in @(Get-Printer)) {
            foreach ($j in @(Get-PrintJob -PrinterName $p.Name)) {
                $rows += [pscustomobject]@{
                    printer = "$($p.Name)"; id = [int]$j.Id; document = "$($j.DocumentName)"; user = "$($j.UserName)"
                    status = "$($j.JobStatus)"; pages = [int]$j.TotalPages
                    submitted = $(if ($j.SubmittedTime) { ([datetime]$j.SubmittedTime).ToUniversalTime().ToString('o') } else { $null })
                }
            }
        }
        $rows | Select-Object -First 200
    }
}
