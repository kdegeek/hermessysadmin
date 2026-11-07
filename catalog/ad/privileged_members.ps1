<# hermes-catalog
id: ad.privileged_members
title: Privileged group members
category: AD hygiene
description: Every member of the built-in privileged groups (Domain, Enterprise and Schema Admins, Administrators, Account, Server, Backup and Print Operators, Replicator, Key Admins, Enterprise Key Admins, Group Policy Creator Owners and DnsAdmins), expanded through nested groups and primary-group membership, with the nesting path, enabled state and replicated last logon. Groups are found by well-known SID or RID, DnsAdmins by name. Members from other domains that cannot be resolved are listed as unresolved.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [group, member, class, enabled, last_logon, via]
tags: [privileged, domain admins, enterprise admins, schema admins, administrators, operators, dnsadmins, admin groups, tier 0, nested groups]
source: In-box ActiveDirectory (Get-ADGroup member attribute walked breadth-first, Get-ADObject, primaryGroupID LDAP filter)
#>
param()
Invoke-Op {
    $dom = Get-ADDomain
    $forest = Get-ADForest
    $domSid = $dom.DomainSID.Value
    $here = @{}
    $rootSrv = @{}
    $rootSid = $domSid
    $errors = @()
    if ($forest.RootDomain -ne $dom.DNSRoot) {
        $rootSrv = @{ Server = $forest.RootDomain }
        try { $rootSid = (Get-ADDomain -Identity $forest.RootDomain).DomainSID.Value } catch { $rootSid = $null }
    }
    $targets = @(
        @{ id = 'S-1-5-32-544'; srv = $here; rid = $null }, @{ id = 'S-1-5-32-548'; srv = $here; rid = $null },
        @{ id = 'S-1-5-32-549'; srv = $here; rid = $null }, @{ id = 'S-1-5-32-550'; srv = $here; rid = $null },
        @{ id = 'S-1-5-32-551'; srv = $here; rid = $null }, @{ id = 'S-1-5-32-552'; srv = $here; rid = $null },
        @{ id = "$domSid-512"; srv = $here; rid = 512 }, @{ id = "$domSid-520"; srv = $here; rid = 520 },
        @{ id = "$domSid-526"; srv = $here; rid = 526 }
    )
    if ($rootSid) {
        $targets += @(@{ id = "$rootSid-518"; srv = $rootSrv; rid = 518 }, @{ id = "$rootSid-519"; srv = $rootSrv; rid = 519 },
            @{ id = "$rootSid-527"; srv = $rootSrv; rid = 527 })
    } else {
        $errors += @{ host = $forest.RootDomain; message = 'Forest root domain SID unavailable; Schema Admins, Enterprise Admins and Enterprise Key Admins not checked.' }
    }
    $dns = @(Get-ADGroup -LDAPFilter '(sAMAccountName=DnsAdmins)')
    if ($dns.Count -eq 1) { $targets += @{ id = $dns[0].DistinguishedName; srv = $here; rid = $null } }

    $cache = @{}
    $props = @('objectClass', 'sAMAccountName', 'userAccountControl', 'lastLogonTimestamp', 'member')
    $rows = New-Object System.Collections.ArrayList
    foreach ($t in $targets) {
        $s = $t.srv
        try { $g = Get-ADGroup -Identity $t.id -Properties member @s -ErrorAction Stop }
        catch { $errors += @{ host = "$($t.id)"; message = "$($_.Exception.Message)" }; continue }
        $seen = @{ "$($g.DistinguishedName)" = $true }
        $queue = New-Object System.Collections.Queue
        foreach ($m in @($g.member)) { $queue.Enqueue(@("$m", '')) }
        if ($t.rid) {
            foreach ($p in @(Get-ADObject -LDAPFilter "(primaryGroupID=$($t.rid))" @s)) { $queue.Enqueue(@("$($p.DistinguishedName)", 'primary group')) }
        }
        while ($queue.Count -gt 0) {
            $item = $queue.Dequeue()
            $dn = $item[0]; $via = $item[1]
            if ($seen.ContainsKey($dn)) { continue }
            $seen[$dn] = $true
            if (-not $cache.ContainsKey($dn)) {
                $o = $null
                try { $o = Get-ADObject -Identity $dn -Properties $props @s -ErrorAction Stop } catch { $o = $null }
                $cache[$dn] = $o
            }
            $o = $cache[$dn]
            if (-not $o) {
                [void]$rows.Add(@{ group = $g.Name; member = (Get-CnName $dn); class = 'unresolved'; enabled = $null; last_logon = $null; via = $via })
                continue
            }
            $cls = "$($o.ObjectClass)"
            $enabled = $null
            if ($null -ne $o.userAccountControl) { $enabled = -not ([int]$o.userAccountControl -band 2) }
            $last = $null
            if ($o.lastLogonTimestamp -and [int64]$o.lastLogonTimestamp -gt 0) { $last = [datetime]::FromFileTimeUtc([int64]$o.lastLogonTimestamp).ToString('o') }
            $name = if ($o.sAMAccountName) { "$($o.sAMAccountName)" } else { "$($o.Name)" }
            [void]$rows.Add(@{ group = $g.Name; member = $name; class = $cls; enabled = $enabled; last_logon = $last; via = $via })
            if ($cls -eq 'group') {
                $next = if ($via -and $via -ne 'primary group') { "$via > $($o.Name)" } else { "$($o.Name)" }
                foreach ($m in @($o.member)) { $queue.Enqueue(@("$m", $next)) }
            }
        }
    }
    $all = @($rows)
    @{ items = @($all | Select-Object -First 500); errors = $errors
       summary = @{ total = $all.Count; truncated = ($all.Count -gt 500); groups_checked = $targets.Count
                    enabled_accounts = @($all | Where-Object { $_['enabled'] -eq $true }).Count
                    disabled_accounts = @($all | Where-Object { $_['enabled'] -eq $false }).Count } }
}
