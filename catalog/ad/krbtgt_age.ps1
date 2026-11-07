<# hermes-catalog
id: ad.krbtgt_age
title: krbtgt password age
category: AD hygiene
description: When the krbtgt account password was last set, and how many days ago. Located by its well-known RID (502), not its name.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [password_last_set, age_days]
tags: [krbtgt, kerberos, password age, golden ticket, rotation, hygiene]
source: In-box ActiveDirectory (Get-ADUser)
#>
param()
Invoke-Op {
    $sid = (Get-ADDomain).DomainSID.Value + '-502'
    $u = Get-ADUser -Identity $sid -Properties PasswordLastSet
    $age = $null
    if ($u.PasswordLastSet) { $age = [int]((Get-Date) - $u.PasswordLastSet).TotalDays }
    @{ items = @(@{ password_last_set = (Iso $u.PasswordLastSet); age_days = $age }); summary = @{ total = 1; truncated = $false } }
}
