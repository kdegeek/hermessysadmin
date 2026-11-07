<# hermes-catalog
id: files.largest_files
title: Largest files under a folder
category: File permissions
description: The largest files under a path on a server, biggest first, with size, last modified time and owner. Walks folders to the given depth on the server itself, skips reparse points and stops after 2000 folders or 100000 files (truncated is then true and the list covers only what was examined). File contents are never read.
module: inbox:Microsoft.PowerShell.Management
target: dc
tier: R
columns: [host, path, size_mb, modified, owner]
tags: [large files, biggest files, disk space, file size, space hogs, cleanup, file server, storage]
source: In-box Get-ChildItem and Get-Acl (owner of the listed files only), run locally on the server through the fan-out
params:
  - {name: Server, type: string, required: true, description: File server host name.}
  - {name: Path, type: string, required: true, description: Absolute local path on the server such as D:\Shares\Data (no wildcards or .. segments).}
  - {name: Depth, type: integer, default: 3, minimum: 0, maximum: 5, description: How many folder levels below Path to walk.}
  - {name: Top, type: integer, default: 50, minimum: 1, maximum: 200, description: How many of the largest files to list.}
#>
param([string]$Server, [string]$Path, [int]$Depth = 3, [int]$Top = 50)
Invoke-Op {
    if ($Server -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z') { throw 'InvalidArguments: Server must be a host name (letters, digits, dots and hyphens)' }
    if ($Path -cnotmatch '\A[A-Za-z]:\\[^:*?<>|"\x00-\x1f]*\z' -or (@($Path -split '[\\/]') -contains '..')) { throw 'InvalidArguments: Path must be an absolute local path such as D:\Shares\Data, without .. segments, wildcards or stream (:) suffixes' }
    $fan = Invoke-HermesCatalogFanout -Computers @($Server) -ArgumentList @($Path, $Depth, $Top) -Script {
        param($root, $depth, $top)
        $ErrorActionPreference = 'Stop'
        if ($depth -lt 0) { $depth = 0 }
        if ($depth -gt 5) { $depth = 5 }
        if ($top -lt 1) { $top = 1 }
        if ($top -gt 200) { $top = 200 }
        if ((Get-Item -LiteralPath $root -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw 'InvalidArguments: Path is a reparse point (junction or symlink); give the real folder path' }
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
                    [void]$files.Add(@{ path = $c.FullName; size = [int64]$c.Length; modified = $c.LastWriteTimeUtc })
                    if ($examined -ge 100000) { break }
                }
            } catch { $skipped++ }
        }
        if ($queue.Count -gt 0 -or $examined -ge 100000) { $capped = ($visited -ge 2000 -or $examined -ge 100000) }
        foreach ($f in @($files | Sort-Object { $_['size'] } -Descending | Select-Object -First $top)) {
            $owner = $null
            try { $owner = (Get-Acl -LiteralPath $f['path']).Owner } catch { $owner = $null }
            [pscustomobject]@{ path = $f['path']; size_mb = [math]::Round($f['size'] / 1MB, 1); modified = $f['modified'].ToString('o'); owner = $owner }
        }
        [pscustomobject]@{ meta = $true; skipped = $skipped; visited = $visited; examined = $examined; capped = $capped }
    }
    $meta = @($fan.items | Where-Object { $_['meta'] })
    $all = @($fan.items | Where-Object { -not $_['meta'] })
    $skipped = 0; $capped = $false; $examined = 0
    foreach ($m in $meta) { $skipped += [int]$m['skipped']; $examined += [int]$m['examined']; $capped = ($capped -or [bool]$m['capped']) }
    @{ items = @($all | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $all.Count; truncated = $capped; files_examined = $examined; folders_visited = $(if ($meta.Count) { [int]$meta[0]['visited'] } else { 0 }); skipped = $skipped; server = $Server; path = $Path; depth = $Depth } }
}
