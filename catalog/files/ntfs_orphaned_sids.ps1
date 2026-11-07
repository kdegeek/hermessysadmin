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
    if ($Server -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$') { throw 'InvalidArguments: Server must be a host name (letters, digits, dots and hyphens)' }
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path -match '[*?<>|"\x00-\x1f]' -or (@($Path -split '[\\/]') -contains '..')) { throw 'InvalidArguments: Path must be an absolute local path such as D:\Shares\Data, without .. segments or wildcards' }
    $fan = Invoke-HermesCatalogFanout -Computers @($Server) -ArgumentList @($Path, $Depth) -Script {
        param($root, $depth)
        $ErrorActionPreference = 'Stop'
        if ($depth -lt 0) { $depth = 0 }
        if ($depth -gt 5) { $depth = 5 }
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue(@($root, 0))
        $emitted = 0
        $known = @{}
        while ($queue.Count -gt 0 -and $emitted -le 500) {
            $item = $queue.Dequeue()
            $dir = $item[0]
            $level = $item[1]
            $acl = Get-Acl -LiteralPath $dir
            foreach ($a in @($acl.Access)) {
                if ($a.IsInherited -and $level -gt 0) { continue }
                $v = "$($a.IdentityReference.Value)"
                if ($v -notmatch '^S-1-5-21-') { continue }
                if (-not $known.ContainsKey($v)) {
                    try { $null = (New-Object System.Security.Principal.SecurityIdentifier($v)).Translate([System.Security.Principal.NTAccount]); $known[$v] = $true } catch { $known[$v] = $false }
                }
                if (-not $known[$v]) {
                    $emitted++
                    [pscustomobject]@{ path = $dir; sid = $v; rights = "$($a.FileSystemRights)" }
                }
            }
            if ($level -lt $depth) {
                foreach ($sub in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
                    if (-not ($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { $queue.Enqueue(@($sub.FullName, ($level + 1))) }
                }
            }
        }
    }
    $all = @($fan.items)
    @{ items = @($all | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $all.Count; truncated = ($all.Count -gt 500); server = $Server; path = $Path; depth = $Depth } }
}
