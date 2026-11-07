<# hermes-catalog
id: ad.empty_groups
title: Empty groups
category: AD hygiene
description: Groups with no members, excluding built-in critical system groups. Groups that only act as a primary group for accounts can appear here.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [name, scope, category]
tags: [empty groups, unused groups, cleanup, group membership, hygiene]
source: In-box ActiveDirectory (Get-ADGroup LDAP filter)
#>
param()
Invoke-Op {
    $rows = @(Get-ADGroup -LDAPFilter '(&(objectClass=group)(!(member=*))(!(isCriticalSystemObject=TRUE)))' |
        Sort-Object Name |
        ForEach-Object { @{ name = $_.Name; scope = "$($_.GroupScope)"; category = "$($_.GroupCategory)" } })
    @{ items = @($rows | Select-Object -First 500); summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500) } }
}
