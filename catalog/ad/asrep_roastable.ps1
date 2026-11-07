<# hermes-catalog
id: ad.asrep_roastable
title: Accounts without Kerberos pre-authentication
category: AD hygiene
description: User accounts with DONT_REQ_PREAUTH (userAccountControl bit 0x400000), which can be AS-REP roasted.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [sam, enabled]
tags: [asrep, as-rep roasting, preauth, dont_req_preauth, kerberos, uac, hygiene]
source: In-box ActiveDirectory (Get-ADUser LDAP filter on userAccountControl)
#>
param()
Invoke-Op {
    $rows = @(Get-ADUser -LDAPFilter '(&(objectCategory=person)(objectClass=user)(userAccountControl:1.2.840.113556.1.4.803:=4194304))' |
        Sort-Object SamAccountName |
        ForEach-Object { @{ sam = $_.SamAccountName; enabled = [bool]$_.Enabled } })
    @{ items = @($rows | Select-Object -First 500); summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500) } }
}
