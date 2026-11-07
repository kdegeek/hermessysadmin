<# hermes-catalog
id: ad.constrained_delegation
title: Constrained and resource-based delegation
category: AD hygiene
description: Accounts set up for Kerberos constrained delegation (msDS-AllowedToDelegateTo), noting those allowed to use any authentication protocol (protocol transition, which can impersonate any user without their password), and accounts with resource-based constrained delegation (msDS-AllowedToActOnBehalfOfOtherIdentity) with the principals allowed to delegate to them. Unconstrained delegation is a separate entry.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [name, class, kind, protocol_transition, delegates_to, allowed_from]
tags: [delegation, constrained delegation, rbcd, resource based, protocol transition, s4u, kerberos, msds-allowedtodelegateto, hygiene]
source: In-box ActiveDirectory (Get-ADObject, Get-ADComputer, Get-ADUser, Get-ADServiceAccount PrincipalsAllowedToDelegateToAccount)
#>
param()
Invoke-Op {
    $errors = @()
    $rows = @(Get-ADObject -LDAPFilter '(msDS-AllowedToDelegateTo=*)' -Properties 'msDS-AllowedToDelegateTo', userAccountControl, sAMAccountName | ForEach-Object {
        $t2a = (([int]$_.userAccountControl -band 16777216) -ne 0)
        $targets = @($_.'msDS-AllowedToDelegateTo' | ForEach-Object { "$_" })
        @{ name = $(if ($_.sAMAccountName) { "$($_.sAMAccountName)" } else { "$($_.Name)" }); class = "$($_.ObjectClass)"
           kind = $(if ($t2a) { 'constrained (any protocol)' } else { 'constrained (Kerberos only)' }); protocol_transition = $t2a
           delegates_to = ((@($targets | Select-Object -First 20)) -join ', ') + $(if ($targets.Count -gt 20) { " (+$($targets.Count - 20) more)" } else { '' })
           allowed_from = '' }
    })
    $rbcdFilter = '(msDS-AllowedToActOnBehalfOfOtherIdentity=*)'
    $sources = @(
        @{ label = 'computer'; get = { Get-ADComputer -LDAPFilter $rbcdFilter -Properties PrincipalsAllowedToDelegateToAccount } },
        @{ label = 'user'; get = { Get-ADUser -LDAPFilter $rbcdFilter -Properties PrincipalsAllowedToDelegateToAccount } },
        @{ label = 'service account'; get = { Get-ADServiceAccount -LDAPFilter $rbcdFilter -Properties PrincipalsAllowedToDelegateToAccount } }
    )
    $seen = @{}
    foreach ($src in $sources) {
        try {
            foreach ($o in @(& $src.get)) {
                if ($seen.ContainsKey($o.DistinguishedName)) { continue }
                $seen[$o.DistinguishedName] = $true
                $from = @($o.PrincipalsAllowedToDelegateToAccount | ForEach-Object { Get-CnName "$_" })
                $rows += @{ name = "$($o.SamAccountName)"; class = "$($o.ObjectClass)"; kind = 'resource-based'; protocol_transition = $null
                            delegates_to = ''; allowed_from = (@($from | Select-Object -First 20) -join ', ') }
            }
        } catch { $errors += @{ host = $src.label; message = "$($_.Exception.Message)" } }
    }
    $rows = @($rows | Sort-Object { $_['kind'] }, { $_['name'] })
    @{ items = @($rows | Select-Object -First 500); errors = $errors
       summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500)
                    protocol_transition = @($rows | Where-Object { $_['protocol_transition'] -eq $true }).Count
                    resource_based = @($rows | Where-Object { $_['kind'] -eq 'resource-based' }).Count } }
}
