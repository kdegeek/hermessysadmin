<# hermes-catalog
id: maint.clear_wu_cache
title: Reset the Windows Update download cache
category: Maintenance
description: Fixes stuck or corrupt update downloads - stops the Windows Update (wuauserv) and BITS services, renames C:\Windows\SoftwareDistribution\Download to Download.old-<timestamp> (Windows recreates it and downloads again) and starts the services that were running. The update history database is not touched and the old folder is kept for you to delete later. Skipped where an update install or servicing operation is in progress. Domain controllers are refused on the computer itself (BITS and Windows Update are not reset on a DC).
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: H
preview: plan
columns: [host, mb, files, renamed_to, restarted, skipped, reason]
tags: [windows update, softwaredistribution, download cache, stuck updates, wuauserv, bits, reset windows update]
source: In-box Stop-Service, Rename-Item, Start-Service and Get-ScheduledTask
#>
param([string[]]$Computers = @(), [string]$Ou, [switch]$Preview)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    # $apply = $false only measures and checks; $true also resets the cache.
    $script = {
        param($apply)
        $ErrorActionPreference = 'Stop'
        $dl = Join-Path $env:windir 'SoftwareDistribution\Download'
        $row = [ordered]@{ mb = $null; files = $null; renamed_to = ''; restarted = ''; skipped = $false; reason = '' }
        if ([int](Get-CimInstance Win32_OperatingSystem).ProductType -eq 2) { $row.skipped = $true; $row.reason = 'refused: domain controller'; return [pscustomobject]$row }
        $item = Get-Item -LiteralPath $dl -Force -ErrorAction SilentlyContinue
        if (-not $item) { $row.skipped = $true; $row.reason = 'no Download folder'; return [pscustomobject]$row }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $row.skipped = $true; $row.reason = 'Download is a junction or symlink; left alone'; return [pscustomobject]$row }
        $n = 0; $bytes = [int64]0
        foreach ($f in @(Get-ChildItem -LiteralPath $dl -File -Recurse -Force -ErrorAction SilentlyContinue | Select-Object -First 100000)) { $n++; $bytes += [int64]$f.Length }
        $row.files = $n; $row.mb = [math]::Round($bytes / 1MB, 1)
        $busy = @()
        $task = $null
        if (Get-Command -Name Get-ScheduledTask -ErrorAction SilentlyContinue) { $task = Get-ScheduledTask -TaskName 'HermesSysadmin-WUInstall' -ErrorAction SilentlyContinue }
        if ($task -and "$($task.State)" -eq 'Running') { $busy += 'a hermes-sysadmin update install is running' }
        if (Get-Process -Name TiWorker -ErrorAction SilentlyContinue) { $busy += 'Windows servicing (TiWorker) is running' }
        try { if ((New-Object -ComObject Microsoft.Update.Installer).IsBusy) { $busy += 'the Windows Update installer is busy' } } catch { }
        if ($busy.Count) { $row.skipped = $true; $row.reason = ($busy -join '; '); return [pscustomobject]$row }
        if (-not $apply) { return [pscustomobject]$row }
        $names = @('wuauserv', 'BITS')
        $wasRunning = @($names | Where-Object { "$((Get-Service -Name $_).Status)" -eq 'Running' })
        $newName = 'Download.old-' + (Get-Date -Format 'yyyyMMddHHmmss')
        try {
            foreach ($s in $names) { Stop-Service -Name $s -ErrorAction Stop }
            foreach ($s in $names) { (Get-Service -Name $s).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30)) }
            Rename-Item -LiteralPath $dl -NewName $newName -ErrorAction Stop
            $row.renamed_to = Join-Path $env:windir "SoftwareDistribution\$newName"
        } finally {
            foreach ($s in $wasRunning) { try { Start-Service -Name $s -ErrorAction Stop } catch { } }
            $row.restarted = ($wasRunning -join ', ')
        }
        [pscustomobject]$row
    }
    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($false) -Script $script
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = @{ mb = $r['mb']; files = $r['files']; skipped = $r['skipped']; reason = $r['reason'] } }
        return @{ summary = "Stop wuauserv and BITS, set aside the Windows Update download cache and restart the services on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object {
                      if ($_['skipped']) { "$($_['host']): skipped - $($_['reason'])" }
                      else { "$($_['host']): stop wuauserv and BITS, rename SoftwareDistribution\Download ($($_['files']) file(s), $($_['mb']) MB) to Download.old-<timestamp>, restart the services" } }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($true) -Script $script
}
