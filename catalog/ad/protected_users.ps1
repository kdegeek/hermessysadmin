<# hermes-catalog
id: ad.protected_users
title: Protected Users coverage
category: AD hygiene
description: Members of the Protected Users group (expanded through nested groups) together with privileged user accounts (Domain, Enterprise and Schema Admins and Administrators, expanded) that are not in it. Notes flag computer and service accounts placed in Protected Users, where it either does nothing or blocks delegation, NTLM and RC4. The group needs a Windows Server 2012 R2 or later domain controller to take effect.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [member, class, enabled, in_protected_users, privileged, has_spn, note]
tags: [protected users, privileged accounts, credential theft, kerberos, ntlm, admins, tier 0, hardening]
source: In-box ActiveDirectory (Get-ADGroupMember -Recursive, Get-ADObject)
#>
param()
Invoke-Op {
    $dom = Get-ADDomain
    $domSid = $dom.DomainSID.Value
    $errors = @()
    $pu = @{}
    try {
        foreach ($m in @(Get-ADGroupMember -Identity "$domSid-525" -Recursive -ErrorAction Stop)) { $pu[$m.DistinguishedName] = $true }
    } catch { $errors += @{ host = 'Protected Users'; message = "$($_.Exception.Message)" } }
    $priv = @{}
    foreach ($sid in @('S-1-5-32-544', "$domSid-512", "$domSid-518", "$domSid-519")) {
        try {
            foreach ($m in @(Get-ADGroupMember -Identity $sid -Recursive -ErrorAction Stop)) {
                if ("$($m.objectClass)" -eq 'user') { $priv[$m.DistinguishedName] = $true }
            }
        } catch { if ($sid -notmatch '-(518|519)$') { $errors += @{ host = $sid; message = "$($_.Exception.Message)" } } }
    }
    $dns = @($pu.Keys) + @($priv.Keys | Where-Object { -not $pu.ContainsKey($_) })
    $rows = @(foreach ($dn in $dns) {
        $o = $null
        try { $o = Get-ADObject -Identity $dn -Properties sAMAccountName, userAccountControl, servicePrincipalName -ErrorAction Stop } catch { }
        if (-not $o) { @{ member = (Get-CnName $dn); class = 'unresolved'; enabled = $null; in_protected_users = $pu.ContainsKey($dn); privileged = $priv.ContainsKey($dn); has_spn = $null; note = '' }; continue }
        $cls = "$($o.ObjectClass)"
        $enabled = $null
        if ($null -ne $o.userAccountControl) { $enabled = -not ([int]$o.userAccountControl -band 2) }
        $spn = (@($o.servicePrincipalName).Count -gt 0)
        $inPu = $pu.ContainsKey($dn)
        $isPriv = $priv.ContainsKey($dn)
        $note = ''
        if ($inPu -and $cls -eq 'computer') { $note = 'Computer accounts get no protection from this group' }
        elseif ($inPu -and $cls -like 'msDS-*ManagedServiceAccount') { $note = 'Managed service account in Protected Users; Kerberos delegation and NTLM are blocked' }
        elseif ($inPu -and $spn) { $note = 'Account with SPNs; delegation, NTLM, DES and RC4 are blocked for it' }
        elseif ($isPriv -and -not $inPu -and $enabled) { $note = 'Privileged and not in Protected Users' }
        @{ member = $(if ($o.sAMAccountName) { "$($o.sAMAccountName)" } else { "$($o.Name)" }); class = $cls; enabled = $enabled
           in_protected_users = $inPu; privileged = $isPriv; has_spn = $spn; note = $note }
    })
    $rows = @($rows | Sort-Object { -not $_['in_protected_users'] }, { $_['member'] })
    @{ items = @($rows | Select-Object -First 500); errors = $errors
       summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); protected_users_members = $pu.Count
                    privileged_not_protected = @($rows | Where-Object { $_['privileged'] -and -not $_['in_protected_users'] }).Count
                    domain_mode = "$($dom.DomainMode)" } }
}
