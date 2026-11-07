<# hermes-catalog
id: ad.stale_computers
title: Stale computer accounts
category: AD hygiene
description: Enabled computer accounts whose last logon is older than N days, or that have never logged on. Uses the replicated LastLogonDate, so it is accurate to about two weeks.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [name, os, last_logon, ou]
tags: [stale, inactive, old computers, cleanup, last logon, computer accounts, hygiene]
source: In-box ActiveDirectory (Get-ADComputer)
params:
  - {name: Days, type: integer, default: 90, minimum: 1, maximum: 3650, description: Accounts with no logon for this many days are listed.}
#>
param([int]$Days = 90)
Invoke-Op {
    $cut = (Get-Date).AddDays(-$Days)
    $rows = @(Get-ADComputer -Filter "Enabled -eq 'True'" -Properties LastLogonDate, OperatingSystem |
        Where-Object { (-not $_.LastLogonDate) -or ($_.LastLogonDate -lt $cut) } |
        Sort-Object LastLogonDate |
        ForEach-Object { @{ name = $_.Name; os = $_.OperatingSystem; last_logon = (Iso $_.LastLogonDate); ou = (Get-ParentDn $_.DistinguishedName) } })
    @{ items = @($rows | Select-Object -First 500); summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); days = $Days } }
}
