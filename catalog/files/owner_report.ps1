<# hermes-catalog
id: files.owner_report
title: Folder owners
category: File permissions
description: Who owns the folders under a path, grouped by owner with the number of folders and an example path, non-administrative owners first. An owner can always change a folder's permissions, so folders owned by ordinary users are worth reviewing. Owners that no longer resolve are shown by SID. Walks folders to the given depth on the server itself, skips reparse points and stops after 2000 folders.
module: inbox:Microsoft.PowerShell.Security
target: dc
tier: R
columns: [host, owner, folders, admin_owned, sample_path]
tags: [ntfs, owner, ownership, folder owner, takeown, acl, file server, permissions]
source: In-box Get-Acl (GetOwner by SID), run locally on the server through the fan-out
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
        # Administrators, SYSTEM, TrustedInstaller, and Domain Admins / Enterprise Admins of any domain.
        $adminSids = @('S-1-5-32-544', 'S-1-5-18', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
        $owners = @{}
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue(@($root, 0))
        $visited = 0
        $skipped = 0
        $capped = $false
        while ($queue.Count -gt 0 -and $visited -lt 2000) {
            $item = $queue.Dequeue()
            $dir = $item[0]
            $level = $item[1]
            $visited++
            try {
                $o = (Get-Acl -LiteralPath $dir).GetOwner([System.Security.Principal.SecurityIdentifier])
                $sid = $(if ($o) { $o.Value } else { '(none)' })
                if (-not $owners.ContainsKey($sid)) { $owners[$sid] = @{ sid = $sid; folders = 0; sample = $dir } }
                $owners[$sid]['folders']++
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
        $rows = @(foreach ($g in $owners.Values) {
            $sid = $g['sid']
            $name = $sid
            if ($sid -like 'S-1-*') {
                try { $name = (New-Object System.Security.Principal.SecurityIdentifier $sid).Translate([System.Security.Principal.NTAccount]).Value } catch { $name = $sid }
            }
            $admin = (($adminSids -contains $sid) -or $sid -match '\AS-1-5-21-\d+-\d+-\d+-(512|519)\z')
            @{ owner = $name; folders = $g['folders']; admin_owned = $admin; sample_path = $g['sample'] }
        })
        foreach ($r in @($rows | Sort-Object @{ Expression = { $_['admin_owned'] } }, @{ Expression = { $_['folders'] }; Descending = $true } | Select-Object -First 500)) { [pscustomobject]$r }
        [pscustomobject]@{ meta = $true; skipped = $skipped; visited = $visited; capped = $capped; owners = $rows.Count }
    }
    $meta = @($fan.items | Where-Object { $_['meta'] })
    $all = @($fan.items | Where-Object { -not $_['meta'] })
    $skipped = 0; $capped = $false
    foreach ($m in $meta) { $skipped += [int]$m['skipped']; $capped = ($capped -or [bool]$m['capped']) }
    @{ items = @($all | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $all.Count; truncated = (($all.Count -gt 500) -or $capped); folders_visited = $(if ($meta.Count) { [int]$meta[0]['visited'] } else { 0 }); skipped = $skipped; server = $Server; path = $Path; depth = $Depth } }
}
