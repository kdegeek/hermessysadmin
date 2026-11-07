<# hermes-catalog
id: gpo.permission_analysis
title: GPO permission analysis
category: Group Policy
description: Every GPO permission entry classified as Administrative (Domain Admins, Enterprise Admins, SYSTEM), Authenticated Users, Unknown (the account no longer resolves) or Other. Unknown and Other entries are listed first.
module: inbox:GroupPolicy
target: dc
tier: R
columns: [name, permission_type, principal, permission]
tags: [gpo, group policy, permissions, acl, analysis, unknown sid, delegation, edit rights]
source: In-box GroupPolicy (Get-GPPermission)
#>
param()
Invoke-Op {
    $domSid = (Get-ADDomain).DomainSID.Value
    $admin = @('S-1-5-18', 'S-1-5-9', "$domSid-512", "$domSid-519", 'S-1-5-32-544')
    $errs = @()
    $rows = @()
    foreach ($g in @(Get-GPO -All | Sort-Object DisplayName)) {
        try {
            foreach ($a in @(Get-GPPermission -Guid $g.Id -All)) {
                $sid = "$($a.Trustee.Sid.Value)"
                $type = 'Other'
                if ($admin -contains $sid) { $type = 'Administrative' }
                elseif ($sid -eq 'S-1-5-11') { $type = 'Authenticated Users' }
                elseif ("$($a.Trustee.SidType)" -eq 'Unknown' -or -not $a.Trustee.Name) { $type = 'Unknown' }
                $who = if ($a.Trustee.Name) { "$($a.Trustee.Name)" } else { $sid }
                $rows += @{ name = $g.DisplayName; permission_type = $type; principal = $who; permission = "$($a.Permission)" }
            }
        } catch { $errs += @{ host = $env:COMPUTERNAME; message = "$($g.DisplayName): $($_.Exception.Message)" } }
    }
    $order = @{ Unknown = 0; Other = 1; 'Authenticated Users' = 2; Administrative = 3 }
    $rows = @($rows | Sort-Object { $order[$_.permission_type] }, { $_.name })
    @{ items = @($rows | Select-Object -First 500); errors = $errs; summary = @{ total = $rows.Count; unknown = @($rows | Where-Object { $_.permission_type -eq 'Unknown' }).Count; truncated = ($rows.Count -gt 500) } }
}
