<# hermes-catalog
id: patch.wu_settings
title: Windows Update client settings (PSWindowsUpdate)
category: Patching
description: Windows Update client settings per computer (WSUS server, automatic update options, schedule) using the PSWindowsUpdate module on the jump host.
module: gallery:PSWindowsUpdate@2.2.1.5
target: endpoint
tier: R
columns: [host, wu_server, use_wsus, au_options, no_auto_update, install_day, install_time]
tags: [windows update, settings, wsus, automatic updates, schedule, pswindowsupdate]
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
            $rows = @(Get-WUSettings -ComputerName $targets -ErrorAction SilentlyContinue -ErrorVariable ev)
            foreach ($e in @($ev)) { $msg = "$($e.Exception.Message)"; $errors += @{ host = "$($e.TargetObject)"; message = $msg.Substring(0, [math]::Min(300, $msg.Length)) } }
            foreach ($r in $rows) {
                # Only the named setting keys are projected, as plain strings; the raw module object is never returned.
                $items += @{ host = "$($r.ComputerName)"; wu_server = "$($r.WUServer)"; use_wsus = "$($r.UseWUServer)"
                             au_options = "$($r.AUOptions)"; no_auto_update = "$($r.NoAutoUpdate)"
                             install_day = "$($r.ScheduledInstallDay)"; install_time = "$($r.ScheduledInstallTime)" }
            }
        } catch {
            $msg = "$($_.Exception.Message)"
            $errors += @{ host = '*'; message = $msg.Substring(0, [math]::Min(300, $msg.Length)) }
        }
    }
    @{ items = $items; errors = $errors; summary = @{ hosts = $targets.Count; rows = $items.Count; failed = $errors.Count } }
}
