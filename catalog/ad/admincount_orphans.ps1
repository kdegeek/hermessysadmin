<# hermes-catalog
id: ad.admincount_orphans
title: AdminCount orphans
category: AD hygiene
description: User accounts with adminCount=1 that are no longer (recursively) members of any protected group, so they keep the locked-down AdminSDHolder ACL for no reason. Protected groups are resolved by well-known SID or RID; krbtgt is excluded.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [sam, enabled]
tags: [admincount, adminsdholder, sdprop, orphaned admins, protected groups, privileged, hygiene]
source: In-box ActiveDirectory (Get-ADUser, Get-ADGroupMember -Recursive)
#>
param()
Invoke-Op {
    $dom = Get-ADDomain
    $domSid = $dom.DomainSID.Value
    $rootSid = $null
    try {
        if ((Get-ADForest).RootDomain -eq $dom.DNSRoot) { $rootSid = $domSid }
        else { $rootSid = (Get-ADDomain -Identity (Get-ADForest).RootDomain).DomainSID.Value }
    } catch { $rootSid = $null }
    $sids = @('S-1-5-32-544', 'S-1-5-32-548', 'S-1-5-32-549', 'S-1-5-32-550', 'S-1-5-32-551', 'S-1-5-32-552',
        "$domSid-512", "$domSid-516", "$domSid-521", "$domSid-526")
    if ($rootSid) { $sids += @("$rootSid-518", "$rootSid-519", "$rootSid-527") }
    $errors = @()
    if (-not $rootSid) { $errors += @{ group = 'forest root'; message = 'Forest root domain SID unavailable; Schema Admins and Enterprise (Key) Admins not checked.' } }
    $protected = @{}
    foreach ($sid in $sids) {
        try {
            $g = Get-ADGroup -Identity $sid -ErrorAction Stop
            foreach ($m in @(Get-ADGroupMember -Identity $g -Recursive -ErrorAction Stop)) { $protected[$m.SID.Value] = $true }
        } catch { $errors += @{ group = $sid; message = "$($_.Exception.Message)" } }
    }
    $rows = @(Get-ADUser -LDAPFilter '(&(objectCategory=person)(objectClass=user)(adminCount=1))' |
        Where-Object { (-not $protected.ContainsKey($_.SID.Value)) -and ($_.SID.Value -ne "$domSid-502") } |
        Sort-Object SamAccountName |
        ForEach-Object { @{ sam = $_.SamAccountName; enabled = [bool]$_.Enabled } })
    @{ items = @($rows | Select-Object -First 500); errors = $errors; summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); groups_checked = ($sids.Count - $errors.Count); groups_failed = $errors.Count } }
}
