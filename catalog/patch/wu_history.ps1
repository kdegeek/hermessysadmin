<# hermes-catalog
id: patch.wu_history
title: Update history (PSWindowsUpdate)
category: Patching
description: Recent Windows Update history per computer (date, KB, title and result) using the PSWindowsUpdate module on the jump host.
module: gallery:PSWindowsUpdate@2.2.1.5
target: endpoint
tier: R
columns: [host, date, kb, title, result]
tags: [update history, patches, installed updates, pswindowsupdate, kb, failed updates]
source: PSGallery PSWindowsUpdate 2.2.1.5 (MIT)
params:
  - {name: Last, type: integer, default: 20, minimum: 1, maximum: 200, description: Number of most recent history entries per computer.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$Last = 20)
Invoke-Op {
    Use-HermesModule -Name PSWindowsUpdate -Version 2.2.1.5
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    $items = @(); $errors = @()
    if ($targets.Count -gt 0) {
        try {
            $ev = $null
            $rows = @(Get-WUHistory -ComputerName $targets -Last $Last -ErrorAction SilentlyContinue -ErrorVariable ev)
            foreach ($e in @($ev)) { $msg = "$($e.Exception.Message)"; $errors += @{ host = "$($e.TargetObject)"; message = $msg.Substring(0, [math]::Min(300, $msg.Length)) } }
            foreach ($g in @($rows | Group-Object -Property ComputerName)) {
                foreach ($r in @($g.Group | Select-Object -First 200)) {
                    $t = "$($r.Title)"
                    $d = $r.Date
                    if ($d -is [datetime]) { $d = $d.ToUniversalTime().ToString('o') }
                    $res = $(if ($r.PSObject.Properties['Result']) { "$($r.Result)" } else { "$($r.Operationname)" })
                    $items += @{ host = "$($r.ComputerName)"; date = "$d"; kb = "$($r.KB)"; title = $t.Substring(0, [math]::Min(300, $t.Length)); result = $res }
                }
            }
        } catch {
            $msg = "$($_.Exception.Message)"
            $errors += @{ host = '*'; message = $msg.Substring(0, [math]::Min(300, $msg.Length)) }
        }
    }
    @{ items = $items; errors = $errors; summary = @{ hosts = $targets.Count; rows = $items.Count; failed = $errors.Count } }
}
