<# hermes-catalog
id: ad.spn_accounts
title: User accounts with service principal names
category: AD hygiene
description: User accounts that carry a servicePrincipalName (Kerberoastable service accounts), excluding krbtgt. Shows at most the first five SPNs per account.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [sam, spns, admin_count, password_last_set]
tags: [spn, kerberoast, service accounts, servicePrincipalName, kerberos, hygiene]
source: In-box ActiveDirectory (Get-ADUser)
#>
param()
Invoke-Op {
    $rows = @(Get-ADUser -LDAPFilter '(&(objectCategory=person)(objectClass=user)(servicePrincipalName=*))' -Properties ServicePrincipalName, AdminCount, PasswordLastSet |
        Where-Object { ($_.SID.Value -notlike '*-502') -and ($_.SamAccountName -notlike 'krbtgt_*') -and ($_.SamAccountName -ne 'krbtgt') } |
        Sort-Object SamAccountName |
        ForEach-Object { @{ sam = $_.SamAccountName; spns = @($_.ServicePrincipalName | Select-Object -First 5 | ForEach-Object { "$_" }); admin_count = [int]$_.AdminCount; password_last_set = (Iso $_.PasswordLastSet) } })
    @{ items = @($rows | Select-Object -First 500); summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500) } }
}
