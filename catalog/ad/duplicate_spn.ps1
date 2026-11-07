<# hermes-catalog
id: ad.duplicate_spn
title: Duplicate SPNs
category: AD hygiene
description: Service principal names registered on more than one object in the domain, which breaks Kerberos for that service. kadmin/changepw is ignored.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [spn, count, objects]
tags: [spn, duplicate spn, setspn, kerberos, service principal name, kerberos errors]
source: In-box ActiveDirectory (Get-ADObject)
#>
param()
Invoke-Op {
    $seen = @{}
    foreach ($o in @(Get-ADObject -LDAPFilter '(servicePrincipalName=*)' -Properties ServicePrincipalName)) {
        foreach ($s in @($o.ServicePrincipalName)) {
            $k = "$s".ToLowerInvariant()
            if ($k -eq 'kadmin/changepw') { continue }
            if (-not $seen.ContainsKey($k)) { $seen[$k] = @{ spn = "$s"; names = New-Object System.Collections.ArrayList } }
            [void]$seen[$k].names.Add("$($o.Name)")
        }
    }
    $rows = @($seen.Values | Where-Object { $_.names.Count -gt 1 } | Sort-Object { $_.spn } |
        ForEach-Object { @{ spn = $_.spn; count = $_.names.Count; objects = @($_.names | Select-Object -First 5) } })
    @{ items = @($rows | Select-Object -First 500); summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500) } }
}
