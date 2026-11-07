<# hermes-catalog
id: gpo.owners
title: GPO owners
category: Group Policy
description: The owner of every GPO and whether it is an administrative group (Domain Admins, Enterprise Admins, Administrators, SYSTEM). GPOs owned by ordinary users or by an account that no longer resolves are listed first.
module: inbox:GroupPolicy
target: dc
tier: R
columns: [name, owner, owner_type, is_admin]
tags: [gpo, group policy, owner, ownership, non-admin owner, unknown owner, security]
source: In-box GroupPolicy (Get-GPO Owner)
#>
param()
Invoke-Op {
    $rows = @(foreach ($g in @(Get-GPO -All)) {
        $owner = "$($g.Owner)"
        $leaf = ($owner -split '\\')[-1]
        $isAdmin = ($leaf -in @('Domain Admins', 'Enterprise Admins', 'Administrators', 'SYSTEM', 'NT AUTHORITY\SYSTEM'))
        $type = 'Other'
        if ($isAdmin) { $type = 'Administrative' }
        elseif (-not $owner -or $owner -match '^S-1-') { $type = 'Unknown' }
        @{ name = $g.DisplayName; owner = $owner; owner_type = $type; is_admin = $isAdmin }
    })
    $rows = @($rows | Sort-Object { $_.is_admin }, { $_.name })
    @{ items = @($rows | Select-Object -First 500); summary = @{ total = $rows.Count; non_admin = @($rows | Where-Object { -not $_.is_admin }).Count; truncated = ($rows.Count -gt 500) } }
}
