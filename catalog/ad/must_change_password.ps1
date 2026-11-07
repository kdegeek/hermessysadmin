<# hermes-catalog
id: ad.must_change_password
title: Users who must change password at next logon
category: AD hygiene
description: User accounts flagged to change their password at next logon (pwdLastSet is 0), with creation date and last logon. Old entries usually mean an account was created or reset and never used, so its initial password is still in place. Disabled accounts are left out unless IncludeDisabled is set. Only the flag is read, never a password.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [sam, name, enabled, created, last_logon, ou]
tags: [must change password, pwdlastset, next logon, initial password, unused accounts, hygiene]
source: In-box ActiveDirectory (Get-ADUser LDAP filter pwdLastSet=0)
params:
  - {name: IncludeDisabled, type: boolean, default: false, description: Also list disabled accounts.}
#>
param([bool]$IncludeDisabled = $false)
Invoke-Op {
    $filter = '(&(objectCategory=person)(objectClass=user)(pwdLastSet=0)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))'
    if ($IncludeDisabled) { $filter = '(&(objectCategory=person)(objectClass=user)(pwdLastSet=0))' }
    $rows = @(Get-ADUser -LDAPFilter $filter -Properties WhenCreated, LastLogonDate |
        Sort-Object WhenCreated |
        ForEach-Object { @{ sam = $_.SamAccountName; name = $_.Name; enabled = [bool]$_.Enabled; created = (Iso $_.WhenCreated)
                            last_logon = (Iso $_.LastLogonDate); ou = (Get-ParentDn $_.DistinguishedName) } })
    @{ items = @($rows | Select-Object -First 500)
       summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); include_disabled = $IncludeDisabled } }
}
