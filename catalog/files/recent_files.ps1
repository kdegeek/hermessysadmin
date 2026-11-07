<# hermes-catalog
id: files.recent_files
title: Recently modified files under a folder
category: File permissions
description: Files under a path on a server that were modified in the last N hours, newest first, with size and modified time. Useful to see what changed on a share, or to spot a burst of rewritten files (ransomware encrypts files in place). Walks folders to the given depth on the server itself, skips reparse points and stops after 2000 folders or 100000 files (truncated is then true). File contents are never read.
module: inbox:Microsoft.PowerShell.Management
target: dc
tier: R
columns: [host, path, size_kb, modified]
tags: [recent files, modified files, changed files, what changed, file server, ransomware, last write time, share activity]
source: In-box Get-ChildItem (LastWriteTimeUtc), run locally on the server through the fan-out
params:
  - {name: Server, type: string, required: true, description: File server host name.}
  - {name: Path, type: string, required: true, description: Absolute local path on the server such as D:\Shares\Data (no wildcards or .. segments).}
  - {name: Hours, type: integer, default: 24, minimum: 1, maximum: 720, description: List files modified within this many hours.}
  - {name: Depth, type: integer, default: 3, minimum: 0, maximum: 5, description: How many folder levels below Path to walk.}
  - {name: Top, type: integer, default: 100, minimum: 1, maximum: 500, description: Most files to list.}
#>
param([string]$Server, [string]$Path, [int]$Hours = 24, [int]$Depth = 3, [int]$Top = 100)
Invoke-Op {
    if ($Server -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z') { throw 'InvalidArguments: Server must be a host name (letters, digits, dots and hyphens)' }
    if ($Path -cnotmatch '\A[A-Za-z]:\\[^:*?<>|"\x00-\x1f]*\z' -or (@($Path -split '[\\/]') -contains '..')) { throw 'InvalidArguments: Path must be an absolute local path such as D:\Shares\Data, without .. segments, wildcards or stream (:) suffixes' }
    $fan = Invoke-HermesCatalogFanout -Computers @($Server) -ArgumentList @($Path, $Hours, $Depth, $Top) -Script {
        param($root, $hours, $depth, $top)
        $ErrorActionPreference = 'Stop'
        if ($depth -lt 0) { $depth = 0 }
        if ($depth -gt 5) { $depth = 5 }
        if ($top -lt 1) { $top = 1 }
        if ($top -gt 500) { $top = 500 }
        if ((Get-Item -LiteralPath $root -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw 'InvalidArguments: Path is a reparse point (junction or symlink); give the real folder path' }
        $cut = (Get-Date).ToUniversalTime().AddHours(-$hours)
        $files = New-Object System.Collections.ArrayList
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue(@($root, 0))
        $visited = 0
        $skipped = 0
        $examined = 0
        $capped = $false
        while ($queue.Count -gt 0 -and $visited -lt 2000 -and $examined -lt 100000) {
            $item = $queue.Dequeue()
            $dir = $item[0]
            $level = $item[1]
            $visited++
            try {
                foreach ($c in @(Get-ChildItem -LiteralPath $dir -Force)) {
                    if ($c.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                    if ($c.PSIsContainer) {
                        if ($level -lt $depth) { $queue.Enqueue(@($c.FullName, ($level + 1))) }
                        continue
                    }
                    $examined++
                    if ($c.LastWriteTimeUtc -ge $cut) { [void]$files.Add(@{ path = $c.FullName; size = [int64]$c.Length; modified = $c.LastWriteTimeUtc }) }
                    if ($examined -ge 100000) { break }
                }
            } catch { $skipped++ }
        }
        if ($queue.Count -gt 0 -or $examined -ge 100000) { $capped = ($visited -ge 2000 -or $examined -ge 100000) }
        foreach ($f in @($files | Sort-Object { $_['modified'] } -Descending | Select-Object -First $top)) {
            [pscustomobject]@{ path = $f['path']; size_kb = [math]::Round($f['size'] / 1KB, 1); modified = $f['modified'].ToString('o') }
        }
        [pscustomobject]@{ meta = $true; skipped = $skipped; visited = $visited; examined = $examined; matched = $files.Count; capped = $capped }
    }
    $meta = @($fan.items | Where-Object { $_['meta'] })
    $all = @($fan.items | Where-Object { -not $_['meta'] })
    $skipped = 0; $capped = $false; $examined = 0; $matched = 0
    foreach ($m in $meta) { $skipped += [int]$m['skipped']; $examined += [int]$m['examined']; $matched += [int]$m['matched']; $capped = ($capped -or [bool]$m['capped']) }
    @{ items = @($all | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $all.Count; matched = $matched; truncated = ($capped -or ($matched -gt $all.Count)); files_examined = $examined; folders_visited = $(if ($meta.Count) { [int]$meta[0]['visited'] } else { 0 }); skipped = $skipped; server = $Server; path = $Path; hours = $Hours; depth = $Depth } }
}
