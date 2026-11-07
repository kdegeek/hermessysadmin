<# hermes-catalog
id: ad.recently_created
title: Recently created users and computers
category: AD hygiene
description: User and computer accounts created in the last N days, newest first, with enabled state, OU and, for computers joined by a non-administrator under the machine account quota, the account that created them (mS-DS-CreatorSID). Unexpected new accounts are a common sign of compromise.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [name, class, created, enabled, creator, ou]
tags: [new accounts, recently created, new users, new computers, whencreated, machine account quota, creator, audit]
source: In-box ActiveDirectory (Get-ADObject LDAP filter on whenCreated, mS-DS-CreatorSID)
params:
  - {name: Days, type: integer, default: 7, minimum: 1, maximum: 365, description: List accounts created within this many days.}
#>
param([int]$Days = 7)
Invoke-Op {
    $since = (Get-Date).ToUniversalTime().AddDays(-$Days).ToString('yyyyMMddHHmmss') + '.0Z'
    $filter = "(&(|(&(objectCategory=person)(objectClass=user))(objectCategory=computer))(whenCreated>=$since))"
    $names = @{}
    $rows = @(Get-ADObject -LDAPFilter $filter -Properties whenCreated, sAMAccountName, userAccountControl, 'mS-DS-CreatorSID' |
        Sort-Object whenCreated -Descending |
        ForEach-Object {
            $creator = $null
            $raw = $_.'mS-DS-CreatorSID'
            if ($raw) {
                $sid = $null
                try {
                    if ($raw -is [byte[]]) { $sid = (New-Object System.Security.Principal.SecurityIdentifier -ArgumentList $raw, 0).Value } else { $sid = "$raw" }
                    if (-not $names.ContainsKey($sid)) {
                        $names[$sid] = try { ([System.Security.Principal.SecurityIdentifier]$sid).Translate([System.Security.Principal.NTAccount]).Value } catch { $sid }
                    }
                    $creator = $names[$sid]
                } catch { $creator = $sid }
            }
            $enabled = $null
            if ($null -ne $_.userAccountControl) { $enabled = -not ([int]$_.userAccountControl -band 2) }
            @{ name = $(if ($_.sAMAccountName) { "$($_.sAMAccountName)" } else { "$($_.Name)" }); class = "$($_.ObjectClass)"
               created = (Iso $_.whenCreated); enabled = $enabled; creator = $creator; ou = (Get-ParentDn $_.DistinguishedName) }
        })
    @{ items = @($rows | Select-Object -First 500)
       summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); days = $Days
                    users = @($rows | Where-Object { $_['class'] -ne 'computer' }).Count; computers = @($rows | Where-Object { $_['class'] -eq 'computer' }).Count } }
}
