<# hermes-catalog
id: ad.sid_history
title: Accounts with SID history
category: AD hygiene
description: Users, computers and groups that carry sIDHistory values, with the SIDs, whether any of them belongs to this domain (never legitimate after a migration) and whether any ends in a privileged RID such as 500, 512, 518, 519 or 544. SID history left over after a finished migration should be cleared.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [name, class, enabled, sid_count, same_domain, privileged_rid, sids]
tags: [sid history, sidhistory, migration, admt, privilege escalation, hygiene]
source: In-box ActiveDirectory (Get-ADObject LDAP filter sIDHistory=*)
#>
param()
Invoke-Op {
    $domSid = (Get-ADDomain).DomainSID.Value
    $privRids = @('500', '512', '516', '518', '519', '520', '526', '527', '544', '548', '549', '550', '551')
    $rows = @(Get-ADObject -LDAPFilter '(sIDHistory=*)' -Properties sIDHistory, sAMAccountName, userAccountControl |
        Sort-Object Name |
        ForEach-Object {
            $sids = @($_.sIDHistory | ForEach-Object { "$_" })
            $enabled = $null
            if ($null -ne $_.userAccountControl) { $enabled = -not ([int]$_.userAccountControl -band 2) }
            @{ name = $(if ($_.sAMAccountName) { "$($_.sAMAccountName)" } else { "$($_.Name)" }); class = "$($_.ObjectClass)"; enabled = $enabled
               sid_count = $sids.Count
               same_domain = [bool](@($sids | Where-Object { $_.StartsWith("$domSid-") }).Count)
               privileged_rid = [bool](@($sids | Where-Object { $privRids -contains ($_ -split '-')[-1] }).Count)
               sids = (@($sids | Select-Object -First 10) -join ', ') }
        })
    @{ items = @($rows | Select-Object -First 500)
       summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500)
                    same_domain = @($rows | Where-Object { $_['same_domain'] }).Count; privileged_rid = @($rows | Where-Object { $_['privileged_rid'] }).Count } }
}
