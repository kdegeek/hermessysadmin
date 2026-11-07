<# hermes-catalog
id: ad.never_expiring_passwords
title: Accounts with never-expiring passwords
category: AD hygiene
description: Enabled user accounts flagged Password never expires, with the date the password was last set.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [sam, name, password_last_set]
tags: [password never expires, password policy, stale password, hygiene, passwordneverexpires]
source: In-box ActiveDirectory (Get-ADUser)
#>
param()
Invoke-Op {
    $rows = @(Get-ADUser -Filter 'Enabled -eq $true -and PasswordNeverExpires -eq $true' -Properties PasswordLastSet |
        Sort-Object PasswordLastSet |
        ForEach-Object { @{ sam = $_.SamAccountName; name = $_.Name; password_last_set = (Iso $_.PasswordLastSet) } })
    @{ items = @($rows | Select-Object -First 500); summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500) } }
}
