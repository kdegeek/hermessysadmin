<# hermes-catalog
id: security.share_open_write
title: Shares writable by broad groups
category: Security posture
description: Non-special SMB shares whose share permissions give Full or Change to a broad group (Everyone, Authenticated Users, Users, Guests, Anonymous Logon, Domain Users, Domain Guests or Domain Computers), matched by SID so it works in any language. Share permissions only; NTFS permissions may still restrict writes. SYSVOL and NETLOGON on domain controllers grant Authenticated Users full share access by design. At most 200 rows per computer.
module: inbox:SmbShare
target: endpoint
tier: R
columns: [host, share, path, account, right]
tags: [shares, smb, everyone, authenticated users, share permissions, writable shares, open shares, ransomware]
source: In-box SmbShare (Get-SmbShare, Get-SmbShareAccess) and .NET SID translation
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $broad = @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545', 'S-1-5-32-546', 'S-1-5-7')
        $rows = @()
        foreach ($s in @(Get-SmbShare | Where-Object { -not $_.Special })) {
            foreach ($ace in @($s | Get-SmbShareAccess -ErrorAction SilentlyContinue)) {
                if ("$($ace.AccessControlType)" -ne 'Allow') { continue }
                if (@('Full', 'Change') -notcontains "$($ace.AccessRight)") { continue }
                $sid = $null
                try { $sid = (New-Object System.Security.Principal.NTAccount("$($ace.AccountName)")).Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { $sid = $null }
                if (-not $sid) { continue }
                if ($broad -contains $sid -or $sid -match '^S-1-5-21-\d+-\d+-\d+-(513|514|515)$') {
                    $rows += [pscustomobject]@{ share = "$($s.Name)"; path = "$($s.Path)"; account = "$($ace.AccountName)"; right = "$($ace.AccessRight)" }
                }
            }
        }
        $rows | Select-Object -First 200
    }
}
