<# hermes-catalog
id: printers.set_paused
title: Pause or resume a printer
category: Printers
description: Pauses or resumes one printer on each computer. A paused printer keeps accepting jobs but holds them in the queue until it is resumed, so nothing is lost. Use it to hold printing while a device is serviced. The preview shows the printer's current status and queued job count.
module: inbox:PrintManagement
target: endpoint
tier: W
preview: plan
columns: [host, printer, action, before, after, jobs]
tags: [printers, pause, resume, hold printing, printer status, queue, offline]
source: In-box Get-Printer, Get-PrintJob and CIM Win32_Printer Pause and Resume methods
params:
  - {name: Printer, type: string, required: true, description: Exact name of the printer to pause or resume.}
  - {name: Action, type: string, required: true, enum: [Pause, Resume], description: Pause holds the queue; Resume releases it.}
#>
param([string[]]$Computers = @(), [string]$Ou, [string]$Printer, [string]$Action, [switch]$Preview)
Invoke-Op {
    if ($Printer -cnotmatch '\A[^\\/:*?"<>|\x00-\x1f]{1,256}\z') { throw 'InvalidArguments: Printer must be a printer name (no \ / : * ? " < > | characters, up to 256 characters)' }
    if (@('Pause', 'Resume') -cnotcontains $Action) { throw 'InvalidArguments: Action must be Pause or Resume' }
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Printer) -Script {
            param($name)
            $ErrorActionPreference = 'Stop'
            $p = @(Get-Printer | Where-Object { $_.Name -ceq $name })
            if ($p.Count -eq 0) { throw "Printer '$name' was not found" }
            [pscustomobject]@{ printer = $name; before = "$($p[0].PrinterStatus)"; jobs = @(Get-PrintJob -PrinterName $name).Count }
        }
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = @{ status = $r['before']; jobs = $r['jobs'] } }
        $verb = $Action.ToLowerInvariant()
        return @{ summary = "$Action printer '$Printer' on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { "$($_['host']): $verb '$Printer' (now $($_['before']), $($_['jobs']) queued job(s))" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable or printer missing ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Printer, $Action) -Script {
        param($name, $act)
        $ErrorActionPreference = 'Stop'
        $p = @(Get-Printer | Where-Object { $_.Name -ceq $name })
        if ($p.Count -eq 0) { throw "Printer '$name' was not found" }
        $before = "$($p[0].PrinterStatus)"
        $w = @(Get-CimInstance Win32_Printer | Where-Object { $_.Name -ceq $name })
        if ($w.Count -ne 1) { throw "Printer '$name' matched $($w.Count) Win32_Printer objects" }
        $rv = Invoke-CimMethod -InputObject $w[0] -MethodName $act
        if ([int]$rv.ReturnValue -ne 0) { throw "$act failed with code $([int]$rv.ReturnValue)" }
        $after = "$((@(Get-Printer | Where-Object { $_.Name -ceq $name }))[0].PrinterStatus)"
        [pscustomobject]@{ printer = $name; action = $act; before = $before; after = $after; jobs = @(Get-PrintJob -PrinterName $name).Count }
    }
}
