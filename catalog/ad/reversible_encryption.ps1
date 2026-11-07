<# hermes-catalog
id: ad.reversible_encryption
title: Accounts storing reversible-encryption passwords
category: AD hygiene
description: User accounts with the ENCRYPTED_TEXT_PWD_ALLOWED flag (userAccountControl bit 0x80), whose passwords are stored in a recoverable form.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [sam, enabled]
tags: [reversible encryption, encrypted text pwd allowed, weak storage, uac, hygiene]
source: In-box ActiveDirectory (Get-ADUser LDAP filter on userAccountControl)
#>
param()
Invoke-Op {
    $rows = @(Get-ADUser -LDAPFilter '(&(objectCategory=person)(objectClass=user)(userAccountControl:1.2.840.113556.1.4.803:=128))' |
        Sort-Object SamAccountName |
        ForEach-Object { @{ sam = $_.SamAccountName; enabled = [bool]$_.Enabled } })
    @{ items = @($rows | Select-Object -First 500); summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500) } }
}
