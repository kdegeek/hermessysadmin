<# hermes-catalog
id: patch.wu_reboot_status
title: Reboot required after updates (PSWindowsUpdate)
category: Patching
description: Whether each computer needs a restart to finish installing updates, using the PSWindowsUpdate module on the jump host. It never restarts anything.
module: gallery:PSWindowsUpdate@2.2.1.5
target: endpoint
tier: R
columns: [host, reboot_required]
tags: [reboot, restart, pending reboot, updates, pswindowsupdate]
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
            # -Silent only reports; without -AutoReboot or -ScheduleReboot the module never restarts a computer.
            $rows = @(Get-WURebootStatus -ComputerName $targets -Silent -ErrorAction SilentlyContinue -ErrorVariable ev)
            foreach ($e in @($ev)) { $msg = "$($e.Exception.Message)"; $errors += @{ host = "$($e.TargetObject)"; message = $msg.Substring(0, [math]::Min(300, $msg.Length)) } }
            foreach ($r in $rows) {
                if ($r -is [bool]) {
                    # Older output shape: a bare boolean, attributable only when a single computer was queried.
                    if ($targets.Count -eq 1) { $items += @{ host = "$($targets[0])"; reboot_required = $r } }
                } elseif ($r.PSObject.Properties['ComputerName']) {
                    $items += @{ host = "$($r.ComputerName)"; reboot_required = [bool]$r.RebootRequired }
                }
            }
        } catch {
            $msg = "$($_.Exception.Message)"
            $errors += @{ host = '*'; message = $msg.Substring(0, [math]::Min(300, $msg.Length)) }
        }
    }
    @{ items = $items; errors = $errors; summary = @{ hosts = $targets.Count; rows = $items.Count; failed = $errors.Count } }
}
