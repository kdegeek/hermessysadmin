<# hermes-catalog
id: gpo.permissions
title: GPO permission check
category: Group Policy
description: Lists the permissions of GPOs where neither Authenticated Users nor Domain Computers can read the policy. Since MS16-072 computers must be able to read a GPO to apply it, so these policies may silently fail to apply.
module: inbox:GroupPolicy
target: dc
tier: R
columns: [name, trustee, permission, flag]
tags: [gpo, group policy, permissions, acl, authenticated users, domain computers, ms16-072, read access]
source: In-box GroupPolicy (Get-GPPermission)
#>
param()
Invoke-Op {
    $dcName = Get-HermesDc
    $domSid = (Get-ADDomain).DomainSID.Value
    $readable = @('GpoRead', 'GpoApply', 'GpoEdit', 'GpoEditDeleteModifySecurity')
    $errs = @()
    $rows = @()
    $flagged = 0
    $checked = 0
    foreach ($g in @(Get-GPO -All | Sort-Object DisplayName)) {
        try {
            $acl = @(Get-GPPermission -Guid $g.Id -All)
            $checked++
            $ok = $false
            foreach ($a in $acl) {
                $sid = "$($a.Trustee.Sid.Value)"
                if (($sid -eq 'S-1-5-11' -or $sid -eq "$domSid-515") -and ("$($a.Permission)" -in $readable)) { $ok = $true }
            }
            if (-not $ok) {
                $flagged++
                foreach ($a in $acl) {
                    $rows += @{ name = $g.DisplayName; trustee = "$($a.Trustee.Name)"; permission = "$($a.Permission)"; flag = 'No read for Authenticated Users or Domain Computers' }
                }
                if ($acl.Count -eq 0) { $rows += @{ name = $g.DisplayName; trustee = ''; permission = ''; flag = 'No permissions at all' } }
            }
        } catch { $errs += @{ host = $dcName; message = "$($g.DisplayName): $($_.Exception.Message)" } }
    }
    @{ items = @($rows | Select-Object -First 500); errors = $errs; summary = @{ total = $rows.Count; flagged_gpos = $flagged; gpos_checked = $checked; truncated = ($rows.Count -gt 500) } }
}
