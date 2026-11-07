<# hermes-catalog
id: ad.password_not_required
title: Accounts that do not require a password
category: AD hygiene
description: User accounts with the PASSWD_NOTREQD flag (userAccountControl bit 0x20), which may have an empty password.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [sam, enabled]
tags: [password not required, passwd_notreqd, empty password, blank password, uac, hygiene]
source: In-box ActiveDirectory (Get-ADUser LDAP filter on userAccountControl)
#>
param()
Invoke-Op {
    $rows = @(Get-ADUser -LDAPFilter '(&(objectCategory=person)(objectClass=user)(userAccountControl:1.2.840.113556.1.4.803:=32))' |
        Sort-Object SamAccountName |
        ForEach-Object { @{ sam = $_.SamAccountName; enabled = [bool]$_.Enabled } })
    @{ items = @($rows | Select-Object -First 500); summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500) } }
}
