<# hermes-catalog
id: ad.ou_tree
title: OU tree with object counts
category: AD hygiene
description: Every organizational unit in tree order with its depth, the users, computers, groups and child OUs directly inside it, the number of GPO links, whether it is protected from accidental deletion and whether it is completely empty (no child objects of any kind). EmptyOnly and UnprotectedOnly narrow the list for cleanup.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [ou, depth, users, computers, groups, sub_ous, gpo_links, protected, empty]
tags: [ou, organizational units, ou structure, empty ou, accidental deletion, protected, gpo links, cleanup, hygiene]
source: In-box ActiveDirectory (Get-ADOrganizationalUnit, Get-ADObject)
params:
  - {name: EmptyOnly, type: boolean, default: false, description: Only list OUs with no child objects at all.}
  - {name: UnprotectedOnly, type: boolean, default: false, description: Only list OUs not protected from accidental deletion.}
#>
param([bool]$EmptyOnly = $false, [bool]$UnprotectedOnly = $false)
Invoke-Op {
    $ous = @(Get-ADOrganizationalUnit -Filter * -Properties ProtectedFromAccidentalDeletion, gPLink)
    $count = @{}
    foreach ($ou in $ous) { $count[$ou.DistinguishedName.ToLowerInvariant()] = @{ user = 0; computer = 0; group = 0; organizationalUnit = 0 } }
    $objs = Get-ADObject -LDAPFilter '(|(&(objectCategory=person)(objectClass=user))(objectCategory=computer)(objectCategory=group)(objectCategory=organizationalUnit))'
    foreach ($o in $objs) {
        $parent = Get-ParentDn $o.DistinguishedName
        if (-not $parent) { continue }
        $c = $count[$parent.ToLowerInvariant()]
        if ($null -eq $c) { continue }
        $cls = "$($o.ObjectClass)"
        if ($cls -eq 'inetOrgPerson') { $cls = 'user' }
        if ($c.ContainsKey($cls)) { $c[$cls]++ }
    }
    $rows = @(foreach ($ou in $ous) {
        $dn = $ou.DistinguishedName
        $c = $count[$dn.ToLowerInvariant()]
        $empty = $false
        if (($c.user + $c.computer + $c.group + $c.organizationalUnit) -eq 0) {
            $empty = (@(Get-ADObject -SearchBase $dn -SearchScope OneLevel -Filter * -ResultSetSize 1).Count -eq 0)
        }
        $protected = [bool]$ou.ProtectedFromAccidentalDeletion
        if ($EmptyOnly -and -not $empty) { continue }
        if ($UnprotectedOnly -and $protected) { continue }
        $rdns = @($dn -split '(?<!\\),')
        [array]::Reverse($rdns)
        @{ ou = $dn; depth = @($rdns | Where-Object { $_ -like 'OU=*' }).Count; users = $c.user; computers = $c.computer; groups = $c.group
           sub_ous = $c.organizationalUnit; gpo_links = ([regex]::Matches("$($ou.gPLink)", '\[LDAP://', 'IgnoreCase')).Count
           protected = $protected; empty = $empty; _key = ($rdns -join ',').ToLowerInvariant() }
    })
    $rows = @($rows | Sort-Object { $_['_key'] })
    foreach ($r in $rows) { $r.Remove('_key') }
    @{ items = @($rows | Select-Object -First 500)
       summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); ous = $ous.Count
                    empty = @($rows | Where-Object { $_['empty'] }).Count; unprotected = @($rows | Where-Object { -not $_['protected'] }).Count } }
}
