<# hermes-catalog
id: files.ntfs_orphaned_sids
title: Orphaned SIDs in NTFS permissions
category: File permissions
description: Explicit permission entries on a folder tree that point to a deleted account (a domain SID that no longer translates). Walks folders to the given depth on the server itself, skips reparse points and returns the first 500 rows. Inherited entries are reported only on the starting folder.
module: inbox:Microsoft.PowerShell.Security
target: dc
tier: R
columns: [host, path, sid, rights]
tags: [ntfs, orphaned sid, unknown account, stale permissions, cleanup, acl, file server]
source: In-box Get-Acl and SecurityIdentifier.Translate, run locally on the server through the fan-out
params:
  - {name: Server, type: string, required: true, description: File server host name.}
  - {name: Path, type: string, required: true, description: Absolute local path on the server such as D:\Shares\Data (no wildcards or .. segments).}
  - {name: Depth, type: integer, default: 2, minimum: 0, maximum: 5, description: How many folder levels below Path to walk.}
#>
param([string]$Server, [string]$Path, [int]$Depth = 2)
Invoke-Op {
    if ($Server -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z') { throw 'InvalidArguments: Server must be a host name (letters, digits, dots and hyphens)' }
    if ($Path -cnotmatch '\A[A-Za-z]:\\[^:*?<>|"\x00-\x1f]*\z' -or (@($Path -split '[\\/]') -contains '..')) { throw 'InvalidArguments: Path must be an absolute local path such as D:\Shares\Data, without .. segments, wildcards or stream (:) suffixes' }
    $fan = Invoke-HermesCatalogFanout -Computers @($Server) -ArgumentList @($Path, $Depth) -Script {
        param($root, $depth)
        $ErrorActionPreference = 'Stop'
        if ($depth -lt 0) { $depth = 0 }
        if ($depth -gt 5) { $depth = 5 }
        if ((Get-Item -LiteralPath $root -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw 'InvalidArguments: Path is a reparse point (junction or symlink); give the real folder path' }
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue(@($root, 0))
        $emitted = 0
        $visited = 0
        $skipped = 0
        $capped = $false
        $known = @{}
        $unresolved = 0
        while ($queue.Count -gt 0 -and $emitted -le 500 -and $visited -lt 2000) {
            $item = $queue.Dequeue()
            $dir = $item[0]
            $level = $item[1]
            $visited++
            try {
                $acl = Get-Acl -LiteralPath $dir
                foreach ($a in @($acl.Access)) {
                    if ($a.IsInherited -and $level -gt 0) { continue }
                    $v = "$($a.IdentityReference.Value)"
                    if ($v -notmatch '^S-1-5-21-') { continue }
                    if (-not $known.ContainsKey($v)) {
                        try { $null = (New-Object System.Security.Principal.SecurityIdentifier($v)).Translate([System.Security.Principal.NTAccount]); $known[$v] = 'ok' }
                        catch [System.Security.Principal.IdentityNotMappedException] { $known[$v] = 'orphan' }
                        catch { $known[$v] = 'unresolved'; $unresolved++ }
                    }
                    if ($known[$v] -eq 'orphan') {
                        $emitted++
                        [pscustomobject]@{ path = $dir; sid = $v; rights = "$($a.FileSystemRights)" }
                    }
                }
            } catch { $skipped++; continue }
            if ($level -lt $depth) {
                try {
                    foreach ($sub in @(Get-ChildItem -LiteralPath $dir -Directory -Force)) {
                        if (-not ($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { $queue.Enqueue(@($sub.FullName, ($level + 1))) }
                    }
                } catch { $skipped++ }
            }
        }
        if ($queue.Count -gt 0 -and $visited -ge 2000) { $capped = $true }
        [pscustomobject]@{ meta = $true; skipped = $skipped; visited = $visited; capped = $capped; unresolved = $unresolved }
    }
    $meta = @($fan.items | Where-Object { $_['meta'] })
    $all = @($fan.items | Where-Object { -not $_['meta'] })
    $skipped = 0; $unres = 0; $capped = $false
    foreach ($m in $meta) { $skipped += [int]$m['skipped']; $capped = ($capped -or [bool]$m['capped']); if ($m.ContainsKey('unresolved')) { $unres += [int]$m['unresolved'] } }
    @{ items = @($all | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $all.Count; truncated = (($all.Count -gt 500) -or $capped); folders_visited = $(if ($meta.Count) { [int]$meta[0]['visited'] } else { 0 }); skipped = $skipped; unresolved_sids = $unres; server = $Server; path = $Path; depth = $Depth } }
}
