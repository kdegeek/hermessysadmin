<# hermes-catalog
id: endpoint.largest_folders
title: Largest folders under a path
category: Endpoint health
description: Sizes the folders that sit Depth levels below Path on each computer and returns the biggest. Junctions and symlinks are never followed. The walk stops after 45 seconds per computer; complete is false when it ran out of time (sizes are then lower bounds) and skipped_dirs counts folders that could not be read.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, path, size_gb, files, complete, skipped_dirs]
tags: [disk space, folder size, largest folders, treesize, du, what is using space, cleanup]
source: In-box Get-ChildItem
params:
  - {name: Path, type: string, default: 'C:\', description: Absolute local folder such as C:\ or D:\Data (no wildcards or .. segments).}
  - {name: Depth, type: integer, default: 1, minimum: 1, maximum: 3, description: How many levels below Path the reported folders sit.}
  - {name: Top, type: integer, default: 20, minimum: 1, maximum: 100, description: How many folders to return per computer.}
#>
param([string[]]$Computers = @(), [string]$Ou, [string]$Path = 'C:\', [int]$Depth = 1, [int]$Top = 20)
Invoke-Op {
    if ($Path -cnotmatch '\A[A-Za-z]:\\[^:*?<>|"\x00-\x1f]*\z' -or (@($Path -split '[\\/]') -contains '..')) { throw 'InvalidArguments: Path must be an absolute local path such as C:\ or D:\Data, without .. segments, wildcards or stream (:) suffixes' }
    if ($Depth -lt 1 -or $Depth -gt 3) { throw 'InvalidArguments: Depth must be 1 to 3' }
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Path, $Depth, $Top) -Script {
        param($root, $depth, $top)
        $ErrorActionPreference = 'Stop'
        $rootItem = Get-Item -LiteralPath $root -Force
        if (-not $rootItem.PSIsContainer) { throw 'InvalidArguments: Path is not a folder' }
        if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'InvalidArguments: Path is a reparse point (junction or symlink); give the real folder path' }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $bytes = @{}; $files = @{}; $skipped = 0; $complete = $true
        # Each stack entry: folder path, its level below root, and the reported folder it belongs to.
        $stack = New-Object System.Collections.Stack
        $stack.Push(@($rootItem.FullName, 0, $null))
        while ($stack.Count -gt 0) {
            if ($clock.Elapsed.TotalSeconds -ge 45) { $complete = $false; break }
            $entry = $stack.Pop()
            $dir = $entry[0]; $level = $entry[1]; $bucket = $entry[2]
            if ($level -eq $depth) { $bucket = $dir; $bytes[$bucket] = [int64]0; $files[$bucket] = 0 }
            $children = $null
            try { $children = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop) } catch { $skipped++; continue }
            foreach ($c in $children) {
                if ($c.PSIsContainer) {
                    if (-not ($c.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push(@($c.FullName, ($level + 1), $bucket)) }
                } elseif ($bucket) {
                    $bytes[$bucket] += [int64]$c.Length; $files[$bucket]++
                }
            }
        }
        $bytes.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $top | ForEach-Object {
            [pscustomobject]@{ path = $_.Key; size_gb = [math]::Round($_.Value / 1GB, 2); files = $files[$_.Key]; complete = $complete; skipped_dirs = $skipped }
        }
    }
}
