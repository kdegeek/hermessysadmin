<# hermes-catalog
id: files.broad_write_access
title: Folders writable by everyone
category: File permissions
description: Folders under a path where Everyone, Anonymous, Authenticated Users, Users or Domain Users are allowed to write, create, delete or change permissions (matched by SID, so it works on any language). Inherited entries are reported only on the starting folder, so each grant shows where it is set. Walks folders to the given depth on the server itself, skips reparse points and stops after 2000 folders. CREATOR OWNER entries are not counted. A system drive root normally shows Users with create-folder rights.
module: inbox:Microsoft.PowerShell.Security
target: dc
tier: R
columns: [host, path, account, rights, inherited, applies_to]
tags: [ntfs, everyone, authenticated users, domain users, write access, modify, full control, open permissions, acl, file server, ransomware exposure]
source: In-box Get-Acl (GetAccessRules by SID), run locally on the server through the fan-out
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
        $broadSids = @('S-1-1-0', 'S-1-5-7', 'S-1-5-11', 'S-1-5-32-545')
        # write data, append, write extended attributes, delete child, write attributes, delete, change permissions, take ownership, generic all, generic write
        $writeMask = 0x500D0156
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
                foreach ($r in @((Get-Acl -LiteralPath $dir).GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
                    if ("$($r.AccessControlType)" -ne 'Allow') { continue }
                    if ($r.IsInherited -and $level -gt 0) { continue }
                    $sid = $r.IdentityReference.Value
                    if (-not (($broadSids -contains $sid) -or $sid -match '\AS-1-5-21-\d+-\d+-\d+-513\z')) { continue }
                    if ((([int64]$r.FileSystemRights) -band $writeMask) -eq 0) { continue }
                    $name = $sid
                    try { $name = $r.IdentityReference.Translate([System.Security.Principal.NTAccount]).Value } catch { $name = $sid }
                    $f = "$($r.InheritanceFlags)"
                    $parts = @()
                    if ("$($r.PropagationFlags)" -notmatch 'InheritOnly') { $parts += 'this folder' }
                    if ($f -match 'ContainerInherit') { $parts += 'subfolders' }
                    if ($f -match 'ObjectInherit') { $parts += 'files' }
                    $emitted++
                    [pscustomobject]@{ path = $dir; account = $name; rights = "$($r.FileSystemRights)"; inherited = [bool]$r.IsInherited; applies_to = ($parts -join ', ') }
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
    $skipped = 0; $capped = $false
    foreach ($m in $meta) { $skipped += [int]$m['skipped']; $capped = ($capped -or [bool]$m['capped']) }
    @{ items = @($all | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $all.Count; truncated = (($all.Count -gt 500) -or $capped); folders_visited = $(if ($meta.Count) { [int]$meta[0]['visited'] } else { 0 }); skipped = $skipped; server = $Server; path = $Path; depth = $Depth } }
}
