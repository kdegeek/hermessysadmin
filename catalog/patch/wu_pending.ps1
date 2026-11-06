<# hermes-catalog
id: patch.wu_pending
title: Pending updates (PSWindowsUpdate)
category: Patching
description: Lists available Windows updates per computer using the PSWindowsUpdate module on the jump host, which contacts each computer itself. Nothing is installed.
module: gallery:PSWindowsUpdate@2.2.1.5
target: endpoint
tier: R
columns: [host, kb, title, size, status]
tags: [updates, patches, pending, pswindowsupdate, available updates, kb]
source: PSGallery PSWindowsUpdate 2.2.1.5 (MIT)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    Use-HermesModule -Name PSWindowsUpdate -Version 2.2.1.5
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    $items = @(); $errors = @()
    if ($targets.Count -gt 0) {
        try {
            $ev = $null
            $rows = @(Get-WindowsUpdate -ComputerName $targets -ErrorAction SilentlyContinue -ErrorVariable ev)
            foreach ($e in @($ev)) { $msg = "$($e.Exception.Message)"; $errors += @{ host = "$($e.TargetObject)"; message = $msg.Substring(0, [math]::Min(300, $msg.Length)) } }
            foreach ($g in @($rows | Group-Object -Property ComputerName)) {
                foreach ($r in @($g.Group | Select-Object -First 200)) {
                    $t = "$($r.Title)"
                    $items += @{ host = "$($r.ComputerName)"; kb = "$($r.KB)"; title = $t.Substring(0, [math]::Min(300, $t.Length)); size = "$($r.Size)"; status = "$($r.Status)" }
                }
            }
        } catch {
            $msg = "$($_.Exception.Message)"
            $errors += @{ host = '*'; message = $msg.Substring(0, [math]::Min(300, $msg.Length)) }
        }
    }
    @{ items = $items; errors = $errors; summary = @{ hosts = $targets.Count; rows = $items.Count; failed = $errors.Count } }
}
