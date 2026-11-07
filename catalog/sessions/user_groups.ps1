<# hermes-catalog
id: sessions.user_groups
title: Effective group membership of a user
category: Users & sessions
description: Every group one user belongs to, directly, through the primary group or through nesting, with the nesting path, scope, type and whether the group is privileged (Administrators, Domain, Enterprise and Schema Admins, the Operators groups, Group Policy Creator Owners, Key Admins, DnsAdmins). Groups in other domains that cannot be resolved are listed as unresolved and not followed further.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [group, scope, category, depth, via, privileged]
tags: [group membership, nested groups, effective access, memberof, user groups, why does user have access, privileged]
source: In-box ActiveDirectory (Get-ADUser, Get-ADGroup memberOf walked breadth-first)
params:
  - {name: Identity, type: string, required: true, description: The user's sAMAccountName or userPrincipalName.}
#>
param([string]$Identity)
Invoke-Op {
    if ($Identity -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._@-]{0,255}\z') { throw "InvalidArguments: Identity must be a sAMAccountName or UPN (letters, digits, '.', '_', '@' or '-', up to 256 characters)" }
    $v = ConvertTo-LdapValue $Identity
    $found = @(Get-ADUser -LDAPFilter "(|(sAMAccountName=$v)(userPrincipalName=$v))" -Properties MemberOf, primaryGroupID)
    if ($found.Count -eq 0) { throw "Cannot find a user with identity '$Identity'." }
    if ($found.Count -gt 1) { throw "Identity '$Identity' matches $($found.Count) users; use the sAMAccountName." }
    $u = $found[0]
    $domSid = (Get-ADDomain).DomainSID.Value
    $privSids = @('S-1-5-32-544', 'S-1-5-32-548', 'S-1-5-32-549', 'S-1-5-32-550', 'S-1-5-32-551', 'S-1-5-32-552')
    $privRids = @('512', '518', '519', '520', '526', '527')
    $queue = New-Object System.Collections.Queue
    foreach ($dn in @($u.MemberOf)) { $queue.Enqueue(@("$dn", 'direct', 1)) }
    if ($u.primaryGroupID) {
        try { $pg = Get-ADGroup -Identity "$domSid-$($u.primaryGroupID)" -ErrorAction Stop; $queue.Enqueue(@("$($pg.DistinguishedName)", 'primary group', 1)) } catch { }
    }
    $seen = @{}
    $rows = New-Object System.Collections.ArrayList
    while ($queue.Count -gt 0 -and $rows.Count -lt 2000) {
        $item = $queue.Dequeue()
        $dn = $item[0]; $via = $item[1]; $depth = [int]$item[2]
        $key = $dn.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $g = $null
        try { $g = Get-ADGroup -Identity $dn -Properties MemberOf -ErrorAction Stop } catch { }
        if (-not $g) {
            [void]$rows.Add(@{ group = (Get-CnName $dn); scope = ''; category = ''; depth = $depth; via = $via; privileged = $null; unresolved = $true })
            continue
        }
        $sid = "$($g.SID.Value)"
        $rid = ($sid -split '-')[-1]
        $priv = ($privSids -contains $sid) -or (($privRids -contains $rid) -and $sid.StartsWith('S-1-5-21-')) -or ($g.SamAccountName -eq 'DnsAdmins')
        [void]$rows.Add(@{ group = $g.Name; scope = "$($g.GroupScope)"; category = "$($g.GroupCategory)"; depth = $depth; via = $via; privileged = [bool]$priv })
        $nextVia = if ($via -eq 'direct' -or $via -eq 'primary group') { $g.Name } else { "$via > $($g.Name)" }
        foreach ($p in @($g.MemberOf)) { $queue.Enqueue(@("$p", $nextVia, ($depth + 1))) }
    }
    $all = @($rows | Sort-Object { $_['depth'] }, { $_['group'] })
    @{ items = @($all | Select-Object -First 500)
       summary = @{ user = $u.SamAccountName; total = $all.Count; truncated = ($all.Count -gt 500)
                    direct = @($all | Where-Object { $_['depth'] -eq 1 }).Count; nested = @($all | Where-Object { $_['depth'] -gt 1 }).Count
                    privileged = @($all | Where-Object { $_['privileged'] -eq $true } | ForEach-Object { $_['group'] }) } }
}
