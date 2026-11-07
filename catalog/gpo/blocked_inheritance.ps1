<# hermes-catalog
id: gpo.blocked_inheritance
title: Blocked inheritance and enforced links
category: Group Policy
description: OUs (and the domain head) that block Group Policy inheritance, with the GPOs linked there and the enforced links higher up the tree that still apply despite the block; then every enforced GPO link. Site-linked GPOs are not included in enforced_above.
module: inbox:GroupPolicy
target: dc
tier: R
columns: [container, kind, gpos, enforced_above, link_enabled]
tags: [block inheritance, blocked, enforced, no override, gpo, group policy, ou, precedence, gpoptions]
source: In-box ActiveDirectory (gPOptions and gPLink on domain and OU objects) and GroupPolicy (Get-GPO for names)
#>
param()
Invoke-Op {
    $domDn = (Get-ADDomain).DistinguishedName
    $names = @{}
    foreach ($g in @(Get-GPO -All)) { $names['{' + $g.Id.ToString().ToUpperInvariant() + '}'] = $g.DisplayName }
    $links = @{}
    $display = @{}
    foreach ($c in @(Get-ADObject -LDAPFilter '(gPLink=*)' -SearchBase $domDn -Properties gPLink)) {
        $key = "$($c.DistinguishedName)".ToLowerInvariant()
        $display[$key] = "$($c.DistinguishedName)"
        $links[$key] = @(foreach ($m in [regex]::Matches("$($c.gPLink)", '\[LDAP://[Cc][Nn]=(\{[0-9A-Fa-f-]+\})[^;]*;(\d)\]')) {
            $guid = $m.Groups[1].Value.ToUpperInvariant()
            $flag = [int]$m.Groups[2].Value
            @{ name = $(if ($names.ContainsKey($guid)) { $names[$guid] } else { "(unknown GPO $guid)" }); enabled = (($flag -band 1) -eq 0); enforced = (($flag -band 2) -ne 0) }
        })
    }
    $rows = @()
    foreach ($b in @(Get-ADObject -LDAPFilter '(gPOptions=1)' -SearchBase $domDn -Properties gPOptions | Sort-Object DistinguishedName)) {
        $dn = "$($b.DistinguishedName)"
        $own = @()
        if ($links.ContainsKey($dn.ToLowerInvariant())) { $own = @($links[$dn.ToLowerInvariant()] | ForEach-Object { $_.name }) }
        $above = @()
        if ($dn.ToLowerInvariant() -ne $domDn.ToLowerInvariant()) {
            $p = Get-ParentDn $dn
            $guard = 0
            while ($p -and $guard -lt 50) {
                $guard++
                $pk = $p.ToLowerInvariant()
                if ($links.ContainsKey($pk)) {
                    foreach ($l in $links[$pk]) { if ($l.enforced -and $l.enabled) { $above += "$($l.name) (linked at $p)" } }
                }
                if ($pk -eq $domDn.ToLowerInvariant()) { break }
                $p = Get-ParentDn $p
            }
        }
        $rows += @{ container = $dn; kind = 'blocks inheritance'; gpos = $own; enforced_above = $above; link_enabled = $null }
    }
    $blockedCount = $rows.Count
    foreach ($key in @($links.Keys | Sort-Object)) {
        foreach ($l in $links[$key]) {
            if ($l.enforced) { $rows += @{ container = $display[$key]; kind = 'enforced link'; gpos = @($l.name); enforced_above = @(); link_enabled = $l.enabled } }
        }
    }
    @{ items = @($rows | Select-Object -First 500); summary = @{ total = $rows.Count; blocked_containers = $blockedCount; enforced_links = ($rows.Count - $blockedCount); truncated = ($rows.Count -gt 500) } }
}
