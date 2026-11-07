<# hermes-catalog
id: ad.unconstrained_delegation
title: Unconstrained delegation
category: AD hygiene
description: Computers and users trusted for unconstrained Kerberos delegation (TRUSTED_FOR_DELEGATION), excluding domain controllers, which always have it.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [name, class]
tags: [delegation, unconstrained, trusted for delegation, kerberos, hygiene]
source: In-box ActiveDirectory (Get-ADComputer, Get-ADUser LDAP filter on userAccountControl)
#>
param()
Invoke-Op {
    $rows = @(
        Get-ADComputer -LDAPFilter '(&(userAccountControl:1.2.840.113556.1.4.803:=524288)(!(userAccountControl:1.2.840.113556.1.4.803:=8192)))' |
            ForEach-Object { @{ name = $_.Name; class = 'computer' } }
        Get-ADUser -LDAPFilter '(&(objectCategory=person)(objectClass=user)(userAccountControl:1.2.840.113556.1.4.803:=524288))' |
            ForEach-Object { @{ name = $_.SamAccountName; class = 'user' } }
    )
    @{ items = @($rows | Select-Object -First 500); summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500) } }
}
