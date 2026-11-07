<# hermes-catalog
id: ad.expiring_accounts
title: User accounts expiring soon
category: AD hygiene
description: User accounts whose account expiration date (accountExpires, not the password) falls within the next N days, optionally with accounts that have already expired. Useful for contractor and temporary accounts.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [sam, name, enabled, expires, status, ou]
tags: [account expiry, expiring accounts, expired accounts, contractors, temporary accounts, accountexpires]
source: In-box ActiveDirectory (Search-ADAccount -AccountExpiring / -AccountExpired)
params:
  - {name: Days, type: integer, default: 30, minimum: 1, maximum: 365, description: List accounts that expire within this many days.}
  - {name: IncludeExpired, type: boolean, default: false, description: Also list accounts that have already expired.}
#>
param([int]$Days = 30, [bool]$IncludeExpired = $false)
Invoke-Op {
    $rows = @(Search-ADAccount -AccountExpiring -TimeSpan ([TimeSpan]::FromDays($Days)) -UsersOnly |
        ForEach-Object { @{ sam = $_.SamAccountName; name = $_.Name; enabled = [bool]$_.Enabled; expires = (Iso $_.AccountExpirationDate)
                            status = 'expiring'; ou = (Get-ParentDn $_.DistinguishedName) } })
    if ($IncludeExpired) {
        $have = @{}; foreach ($r in $rows) { $have[$r['sam']] = $true }
        $rows += @(Search-ADAccount -AccountExpired -UsersOnly | Where-Object { -not $have.ContainsKey($_.SamAccountName) } |
            ForEach-Object { @{ sam = $_.SamAccountName; name = $_.Name; enabled = [bool]$_.Enabled; expires = (Iso $_.AccountExpirationDate)
                                status = 'expired'; ou = (Get-ParentDn $_.DistinguishedName) } })
    }
    $rows = @($rows | Sort-Object { $_['expires'] })
    @{ items = @($rows | Select-Object -First 500)
       summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); days = $Days
                    expiring = @($rows | Where-Object { $_['status'] -eq 'expiring' }).Count; expired = @($rows | Where-Object { $_['status'] -eq 'expired' }).Count } }
}
