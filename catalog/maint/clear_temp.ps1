<# hermes-catalog
id: maint.clear_temp
title: Clear temporary files
category: Maintenance
description: Deletes files (never folders) older than a set number of days from the Windows temp folder and each user's temp folder. Junctions and symlinks are not followed.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: W
preview: plan
columns: [host, files, mb]
tags: [temp, cleanup, disk space, free space, junk]
source: In-box Get-ChildItem and Remove-Item
params:
  - {name: OlderThanDays, type: integer, default: 7, minimum: 1, maximum: 3650, description: Only delete files last modified more than this many days ago.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$OlderThanDays = 7, [switch]$Preview)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    # One script serves both modes: $delete=$false only measures, $delete=$true removes and reports what was freed.
    $script = {
        param($days, $delete)
        $ErrorActionPreference = 'Continue'
        $cutoff = (Get-Date).AddDays(-$days)
        $roots = @('C:\Windows\Temp')
        $roots += @(Get-ChildItem -LiteralPath 'C:\Users' -Directory -Force -Attributes '!ReparsePoint' -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'AppData\Local\Temp' })
        $files = 0; $bytes = [int64]0
        $pending = New-Object System.Collections.Generic.Stack[string]
        foreach ($root in $roots) {
            $item = Get-Item -LiteralPath $root -Force -ErrorAction SilentlyContinue
            if ($item -and $item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $pending.Push($root) }
        }
        while ($pending.Count -gt 0) {
            $dir = $pending.Pop()
            # Files that are not reparse points; directories are walked manually so junctions are never entered.
            foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Force -Attributes '!ReparsePoint' -ErrorAction SilentlyContinue)) {
                if ($f.LastWriteTime -ge $cutoff) { continue }
                if ($delete) {
                    try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch { continue }
                }
                $files++; $bytes += $f.Length
            }
            foreach ($d in @(Get-ChildItem -LiteralPath $dir -Directory -Force -Attributes '!ReparsePoint' -ErrorAction SilentlyContinue)) { $pending.Push($d.FullName) }
        }
        [pscustomobject]@{ files = $files; mb = [math]::Round($bytes / 1MB, 1) }
    }
    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($OlderThanDays, $false) -Script $script
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = @{ files = $r['files']; mb = $r['mb'] } }
        return @{ summary = "Delete temp files older than $OlderThanDays day(s) on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { "$($_['host']): delete $($_['files']) file(s), $($_['mb']) MB" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($OlderThanDays, $true) -Script $script
}
