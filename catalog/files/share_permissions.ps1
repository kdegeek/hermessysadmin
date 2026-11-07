<# hermes-catalog
id: files.share_permissions
title: SMB share permissions
category: File permissions
description: Share-level permissions of every non-special SMB share on a server (or one named share), with account, Full/Change/Read and allow or deny. broad marks Everyone, Anonymous Logon, Authenticated Users, Users or Domain Users with Change or Full at share level (matched by SID). ntfs_broad_write says whether the shared folder's own NTFS permissions also let one of those groups write (matched by SID), which is what makes a broad share permission effective. The read runs on the server itself.
module: inbox:SmbShare
target: dc
tier: R
columns: [host, share, path, account, access, type, broad, ntfs_broad_write]
tags: [share permissions, smb, file share, everyone, full control, change, share acl, Get-SmbShareAccess, file server, open shares]
source: In-box Get-SmbShare, Get-SmbShareAccess, Get-Acl and .NET SID translation, run locally on the server through the fan-out
params:
  - {name: Server, type: string, required: true, description: File server host name.}
  - {name: Share, type: string, description: Only this share name. Omit for every non-special share.}
#>
param([string]$Server, [string]$Share)
Invoke-Op {
    if ($Server -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z') { throw 'InvalidArguments: Server must be a host name (letters, digits, dots and hyphens)' }
    if ($Share -and $Share -cnotmatch '\A[^\\/:*?"<>|\[\]=;,+\x00-\x1f]{1,80}\z') { throw 'InvalidArguments: Share must be a share name of 1-80 characters without \ / : * ? " < > | [ ] = ; , +' }
    $fan = Invoke-HermesCatalogFanout -Computers @($Server) -ArgumentList @($Share) -Script {
        param($only)
        $ErrorActionPreference = 'Stop'
        $broadSids = @('S-1-1-0', 'S-1-5-7', 'S-1-5-11', 'S-1-5-32-545')
        $writeMask = 0x500D0156
        if ($only) { $shares = @(Get-SmbShare -Name $only) } else { $shares = @(Get-SmbShare | Where-Object { -not $_.Special } | Select-Object -First 200) }
        foreach ($s in $shares) {
            $ntfs = $null
            if ($s.Path -and (Test-Path -LiteralPath $s.Path)) {
                try {
                    $ntfs = $false
                    foreach ($r in @((Get-Acl -LiteralPath $s.Path).GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
                        $sid = $r.IdentityReference.Value
                        if ("$($r.AccessControlType)" -eq 'Allow' -and (($broadSids -contains $sid) -or $sid -match '\AS-1-5-21-\d+-\d+-\d+-513\z') -and (([int64]$r.FileSystemRights -band $writeMask) -ne 0)) { $ntfs = $true; break }
                    }
                } catch { $ntfs = $null }
            }
            foreach ($a in @($s | Get-SmbShareAccess)) {
                $acct = "$($a.AccountName)"
                $right = "$($a.AccessRight)"
                $sid = $null
                try { $sid = (New-Object System.Security.Principal.NTAccount $acct).Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { $sid = $null }
                $isBroadAcct = $(if ($sid) { ($broadSids -contains $sid) -or $sid -match '\AS-1-5-21-\d+-\d+-\d+-513\z' } else { $acct -eq 'Everyone' -or $acct -match '\\(Authenticated Users|Users|Domain Users)\z' })
                $isBroad = ("$($a.AccessControlType)" -eq 'Allow' -and ($right -eq 'Full' -or $right -eq 'Change') -and $isBroadAcct)
                [pscustomobject]@{ share = "$($s.Name)"; path = "$($s.Path)"; account = $acct; access = $right; type = "$($a.AccessControlType)"; broad = $isBroad; ntfs_broad_write = $ntfs }
            }
        }
    }
    $all = @($fan.items)
    @{ items = @($all | Select-Object -First 500); errors = $fan.errors; summary = @{ total = $all.Count; broad = @($all | Where-Object { $_['broad'] }).Count; truncated = ($all.Count -gt 500); server = $Server } }
}
