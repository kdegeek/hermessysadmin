<# hermes-catalog
id: ad.disabled_in_groups
title: Disabled users still in groups
category: AD hygiene
description: Disabled user accounts that are still direct members of groups (the primary group, usually Domain Users, is not counted), flagging those still in a privileged group such as Domain Admins, Administrators or an Operators group. Re-enabling such an account restores all of its access at once.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [sam, name, group_count, privileged_groups, groups, ou]
tags: [disabled users, leavers, group membership, cleanup, privileged, offboarding, hygiene]
source: In-box ActiveDirectory (Get-ADUser LDAP filter on the disabled flag, memberOf)
params:
  - {name: PrivilegedOnly, type: boolean, default: false, description: Only list disabled users still in a privileged group.}
#>
param([bool]$PrivilegedOnly = $false)
Invoke-Op {
    $dom = Get-ADDomain
    $domSid = $dom.DomainSID.Value
    $privSids = @('S-1-5-32-544', 'S-1-5-32-548', 'S-1-5-32-549', 'S-1-5-32-550', 'S-1-5-32-551', 'S-1-5-32-552',
        "$domSid-512", "$domSid-518", "$domSid-519", "$domSid-520", "$domSid-526", "$domSid-527")
    $priv = @{}
    foreach ($sid in $privSids) {
        try { $g = Get-ADGroup -Identity $sid -ErrorAction Stop; $priv[$g.DistinguishedName.ToLowerInvariant()] = $g.Name } catch { }
    }
    foreach ($g in @(Get-ADGroup -LDAPFilter '(sAMAccountName=DnsAdmins)')) { $priv[$g.DistinguishedName.ToLowerInvariant()] = $g.Name }
    $rows = @(Get-ADUser -LDAPFilter '(&(objectCategory=person)(objectClass=user)(userAccountControl:1.2.840.113556.1.4.803:=2))' -Properties MemberOf |
        Where-Object { @($_.MemberOf).Count -gt 0 } |
        ForEach-Object {
            $groups = @($_.MemberOf | ForEach-Object { "$_" })
            $p = @($groups | Where-Object { $priv.ContainsKey($_.ToLowerInvariant()) } | ForEach-Object { $priv[$_.ToLowerInvariant()] })
            @{ sam = $_.SamAccountName; name = $_.Name; group_count = $groups.Count; privileged_groups = ($p -join ', ')
               groups = (@($groups | Select-Object -First 20 | ForEach-Object { Get-CnName $_ }) -join ', '); ou = (Get-ParentDn $_.DistinguishedName) }
        } |
        Where-Object { -not $PrivilegedOnly -or $_['privileged_groups'] } |
        Sort-Object { -[int]$_['group_count'] })
    @{ items = @($rows | Select-Object -First 500)
       summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); in_privileged_groups = @($rows | Where-Object { $_['privileged_groups'] }).Count } }
}
