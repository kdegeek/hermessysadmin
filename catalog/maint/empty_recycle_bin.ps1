<# hermes-catalog
id: maint.empty_recycle_bin
title: Empty recycle bins
category: Maintenance
description: Permanently deletes items from every user's Recycle Bin on each fixed drive, optionally only items deleted more than OlderThanDays ago (0 means all). Deleted items cannot be restored. Junctions and symlinks inside deleted folders are removed as links and never followed. Each computer stops after 45 seconds; partial is then true and the rest is left in place. Domain controllers are refused on the computer itself.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: H
preview: plan
destructive: true
columns: [host, items, files, mb, failed, partial]
tags: [recycle bin, empty, trash, disk space, free space, cleanup]
source: In-box Get-ChildItem and Remove-Item over <drive>:\$Recycle.Bin\<SID>
params:
  - {name: OlderThanDays, type: integer, default: 0, minimum: 0, maximum: 3650, description: Only items deleted more than this many days ago. 0 empties the bins completely.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$OlderThanDays = 0, [switch]$Preview)
Invoke-Op {
    if ($OlderThanDays -lt 0) { throw 'InvalidArguments: OlderThanDays must be 0 or more' }
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    # One script serves both modes: $delete=$false only measures, $delete=$true removes and reports what was freed.
    $script = {
        param($days, $delete)
        $ErrorActionPreference = 'Continue'
        if ([int](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).ProductType -eq 2) {
            if ($delete) { throw "PolicyBlocked: refusing to empty recycle bins on $env:COMPUTERNAME`: it is a domain controller." }
            return [pscustomobject]@{ items = 0; files = 0; mb = 0; failed = 0; partial = $false; refused = 'domain controller' }
        }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $cutoff = (Get-Date).AddDays(-$days)
        $rp = [IO.FileAttributes]::ReparsePoint
        $items = 0; $failed = 0; $partial = $false
        # Counters live in a hashtable so the nested function updates the same object.
        $acc = @{ files = 0; bytes = [int64]0 }
        # Measures (and with $delete removes) one $R entry without ever entering a junction or symlink.
        function Clear-Entry($item) {
            if (-not $item.PSIsContainer) {
                $acc.files++; $acc.bytes += [int64]$item.Length
                if ($delete) { Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop }
                return
            }
            if ($item.Attributes -band $rp) { if ($delete) { [IO.Directory]::Delete($item.FullName, $false) }; return }
            $dirs = New-Object System.Collections.Generic.List[string]
            $stack = New-Object System.Collections.Generic.Stack[string]
            $stack.Push($item.FullName)
            while ($stack.Count -gt 0) {
                $d = $stack.Pop(); $dirs.Add($d)
                foreach ($c in @(Get-ChildItem -LiteralPath $d -Force -ErrorAction Stop)) {
                    if ($c.PSIsContainer) {
                        if ($c.Attributes -band $rp) { if ($delete) { [IO.Directory]::Delete($c.FullName, $false) } }
                        else { $stack.Push($c.FullName) }
                    } else {
                        $acc.files++; $acc.bytes += [int64]$c.Length
                        if ($delete) { Remove-Item -LiteralPath $c.FullName -Force -ErrorAction Stop }
                    }
                }
            }
            if ($delete) {
                for ($i = $dirs.Count - 1; $i -ge 0; $i--) {
                    $di = Get-Item -LiteralPath $dirs[$i] -Force -ErrorAction Stop
                    $di.Attributes = 'Directory'
                    [IO.Directory]::Delete($dirs[$i], $false)
                }
            }
        }
        foreach ($disk in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction SilentlyContinue)) {
            $root = "$($disk.DeviceID)\`$Recycle.Bin"
            $ri = Get-Item -LiteralPath $root -Force -ErrorAction SilentlyContinue
            if (-not $ri -or ($ri.Attributes -band $rp)) { continue }
            foreach ($sidDir in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
                if (($sidDir.Attributes -band $rp) -or $sidDir.Name -notmatch '\AS-1-[0-9-]+\z') { continue }
                foreach ($info in @(Get-ChildItem -LiteralPath $sidDir.FullName -Filter '$I*' -File -Force -ErrorAction SilentlyContinue)) {
                    if ($clock.Elapsed.TotalSeconds -ge 45) { $partial = $true; break }
                    # The $I file is written when the item is deleted, so its time is the deletion time.
                    if ($days -gt 0 -and $info.LastWriteTime -ge $cutoff) { continue }
                    try {
                        $data = Get-Item -LiteralPath (Join-Path $sidDir.FullName ('$R' + $info.Name.Substring(2))) -Force -ErrorAction SilentlyContinue
                        if ($data) { Clear-Entry $data }
                        if ($delete) { Remove-Item -LiteralPath $info.FullName -Force -ErrorAction Stop }
                        $items++
                    } catch { $failed++ }
                }
            }
        }
        [pscustomobject]@{ items = $items; files = $acc.files; mb = [math]::Round($acc.bytes / 1MB, 1); failed = $failed; partial = $partial }
    }
    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($OlderThanDays, $false) -Script $script
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = @{ items = $r['items']; files = $r['files']; mb = $r['mb'] } }
        $scope = if ($OlderThanDays -gt 0) { "deleted more than $OlderThanDays day(s) ago" } else { 'in the bins' }
        return @{ summary = "Permanently delete Recycle Bin items $scope on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { if ($_['refused']) { "$($_['host']): refused, $($_['refused']); nothing changes" } else { "$($_['host']): permanently delete $($_['items']) item(s), $($_['files']) file(s), $($_['mb']) MB" + $(if ($_['partial']) { ' (count incomplete: time limit)' } else { '' }) } }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($OlderThanDays, $true) -Script $script
}
