<# hermes-catalog
id: ad.kerberos_accounts
title: Kerberos ticket-granting accounts
category: AD hygiene
description: The krbtgt account and any per-RODC krbtgt_N accounts with the date their password was last set and its age in days.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [domain, name, password_last_set, age_days]
tags: [krbtgt, kerberos, rodc, password age, golden ticket, rotation]
source: In-box ActiveDirectory (Get-ADUser)
#>
param()
Invoke-Op {
    $domain = (Get-ADDomain).DNSRoot
    $rows = @(Get-ADUser -LDAPFilter '(&(objectCategory=person)(objectClass=user)(sAMAccountName=krbtgt*))' -Properties PasswordLastSet |
        Sort-Object SamAccountName | ForEach-Object {
            $age = $null
            if ($_.PasswordLastSet) { $age = [int]((Get-Date) - $_.PasswordLastSet).TotalDays }
            @{ domain = $domain; name = $_.SamAccountName; password_last_set = (Iso $_.PasswordLastSet); age_days = $age } })
    @{ items = @($rows | Select-Object -First 500); summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500) } }
}
