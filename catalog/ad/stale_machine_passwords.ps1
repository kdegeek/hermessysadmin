<# hermes-catalog
id: ad.stale_machine_passwords
title: Computers not rotating their account password
category: AD hygiene
description: Enabled computer accounts whose machine account password was last changed more than N days ago (Windows changes it every 30 days by default), with the replicated last logon. still_logging_on marks computers that log on but do not rotate, which points at a broken secure channel, a restored or cloned machine, a policy that disables the change, or a non-Windows device. Only the date of the last change is read.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [name, os, password_last_set, last_logon, still_logging_on, ou]
tags: [machine account password, pwdlastset, secure channel, computer accounts, stale computers, cloned machines, hygiene]
source: In-box ActiveDirectory (Get-ADComputer PasswordLastSet, LastLogonDate)
params:
  - {name: Days, type: integer, default: 60, minimum: 31, maximum: 3650, description: List computers whose machine password is older than this many days.}
#>
param([int]$Days = 60)
Invoke-Op {
    $cut = (Get-Date).AddDays(-$Days)
    $rows = @(Get-ADComputer -Filter "Enabled -eq 'True'" -Properties PasswordLastSet, LastLogonDate, OperatingSystem |
        Where-Object { $_.PasswordLastSet -and $_.PasswordLastSet -lt $cut } |
        Sort-Object PasswordLastSet |
        ForEach-Object { @{ name = $_.Name; os = $_.OperatingSystem; password_last_set = (Iso $_.PasswordLastSet); last_logon = (Iso $_.LastLogonDate)
                            still_logging_on = [bool]($_.LastLogonDate -and $_.LastLogonDate -gt $cut); ou = (Get-ParentDn $_.DistinguishedName) } })
    @{ items = @($rows | Select-Object -First 500)
       summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); days = $Days; still_logging_on = @($rows | Where-Object { $_['still_logging_on'] }).Count } }
}
