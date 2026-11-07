<# hermes-catalog
id: files.ntfs_inheritance
title: Folders with inheritance disabled
category: File permissions
description: Folders under a path where NTFS permission inheritance is turned off (the folder has its own protected ACL). Walks folders to the given depth on the server itself and skips reparse points. audit_inherited is empty when the audit rules cannot be read.
module: inbox:Microsoft.PowerShell.Security
target: dc
tier: R
columns: [host, path, access_inherited, audit_inherited]
tags: [ntfs, inheritance, protected, blocked inheritance, acl, permissions, file server]
source: In-box Get-Acl (AreAccessRulesProtected), run locally on the server through the fan-out
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
        while ($queue.Count -gt 0 -and $emitted -le 500 -and $visited -lt 2000) {
            $item = $queue.Dequeue()
            $dir = $item[0]
            $level = $item[1]
            $visited++
            try {
                $acl = Get-Acl -LiteralPath $dir
                if ($acl.AreAccessRulesProtected) {
                    $audit = $null
                    try { $audit = -not (Get-Acl -LiteralPath $dir -Audit -ErrorAction Stop).AreAuditRulesProtected } catch { $audit = $null }
                    $emitted++
                    [pscustomobject]@{ path = $dir; access_inherited = $false; audit_inherited = $audit }
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
        [pscustomobject]@{ meta = $true; skipped = $skipped; visited = $visited; capped = $capped }
    }
    $meta = @($fan.items | Where-Object { $_['meta'] })
    $all = @($fan.items | Where-Object { -not $_['meta'] })
    $skipped = 0; $unres = 0; $capped = $false
    foreach ($m in $meta) { $skipped += [int]$m['skipped']; $capped = ($capped -or [bool]$m['capped']); if ($m.ContainsKey('unresolved')) { $unres += [int]$m['unresolved'] } }
    @{ items = @($all | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $all.Count; truncated = (($all.Count -gt 500) -or $capped); folders_visited = $(if ($meta.Count) { [int]$meta[0]['visited'] } else { 0 }); skipped = $skipped; unresolved_sids = $unres; server = $Server; path = $Path; depth = $Depth } }
}
