<# hermes-catalog
id: files.ntfs_access
title: NTFS permissions on a folder
category: File permissions
description: The access control entries on a folder or file on a server, with account, rights, allow or deny, whether inherited and what the entry applies to. The path is a local path on that server (for example D:\Shares\Data); the read runs on the server itself.
module: inbox:Microsoft.PowerShell.Security
target: dc
tier: R
columns: [host, account, rights, type, inherited, applies_to]
tags: [ntfs, permissions, acl, access, folder, share, file server, security descriptor]
source: In-box Get-Acl, run locally on the server through the fan-out
params:
  - {name: Server, type: string, required: true, description: File server host name.}
  - {name: Path, type: string, required: true, description: Absolute local path on the server such as D:\Shares\Data (no wildcards or .. segments).}
#>
param([string]$Server, [string]$Path)
Invoke-Op {
    if ($Server -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z') { throw 'InvalidArguments: Server must be a host name (letters, digits, dots and hyphens)' }
    if ($Path -cnotmatch '\A[A-Za-z]:\\[^:*?<>|"\x00-\x1f]*\z' -or (@($Path -split '[\\/]') -contains '..')) { throw 'InvalidArguments: Path must be an absolute local path such as D:\Shares\Data, without .. segments, wildcards or stream (:) suffixes' }
    $fan = Invoke-HermesCatalogFanout -Computers @($Server) -ArgumentList @($Path) -Script {
        param($p)
        $ErrorActionPreference = 'Stop'
        $acl = Get-Acl -LiteralPath $p
        foreach ($a in @($acl.Access | Select-Object -First 501)) {
            $f = "$($a.InheritanceFlags)"
            $parts = @()
            if ("$($a.PropagationFlags)" -notmatch 'InheritOnly') { $parts += 'this folder' }
            if ($f -match 'ContainerInherit') { $parts += 'subfolders' }
            if ($f -match 'ObjectInherit') { $parts += 'files' }
            $applies = $parts -join ', '
            if ("$($a.PropagationFlags)" -match 'NoPropagateInherit') { $applies += ' (one level only)' }
            [pscustomobject]@{ account = "$($a.IdentityReference.Value)"; rights = "$($a.FileSystemRights)"; type = "$($a.AccessControlType)"; inherited = [bool]$a.IsInherited; applies_to = $applies }
        }
    }
    $all = @($fan.items)
    @{ items = @($all | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $all.Count; truncated = ($all.Count -gt 500); server = $Server; path = $Path } }
}
