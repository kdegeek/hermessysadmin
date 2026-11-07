<# hermes-catalog
id: ad.stale_users
title: Stale user accounts
category: AD hygiene
description: Enabled user accounts whose last logon is older than N days, or that have never logged on and were created before that cutoff. Uses the replicated LastLogonDate, so it is accurate to about two weeks.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [sam, name, last_logon, ou]
tags: [stale, inactive, old users, cleanup, last logon, dormant accounts, hygiene]
source: In-box ActiveDirectory (Get-ADUser)
params:
  - {name: Days, type: integer, default: 90, minimum: 14, maximum: 3650, description: Accounts with no logon for this many days are listed.}
#>
param([int]$Days = 90)
Invoke-Op {
    $cut = (Get-Date).AddDays(-$Days)
    $rows = @(Get-ADUser -Filter "Enabled -eq 'True'" -Properties LastLogonDate, WhenCreated |
        Where-Object { if ($_.LastLogonDate) { $_.LastLogonDate -lt $cut } else { $_.WhenCreated -lt $cut } } |
        Sort-Object LastLogonDate |
        ForEach-Object { @{ sam = $_.SamAccountName; name = $_.Name; last_logon = (Iso $_.LastLogonDate); ou = (Get-ParentDn $_.DistinguishedName) } })
    @{ items = @($rows | Select-Object -First 500); summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); days = $Days } }
}
