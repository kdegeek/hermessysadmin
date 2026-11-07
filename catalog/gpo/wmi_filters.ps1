<# hermes-catalog
id: gpo.wmi_filters
title: WMI filters and the GPOs that use them
category: Group Policy
description: Every WMI filter in the domain with its WQL queries (namespace and query text) and the GPOs that use it. Filters used by no GPO show gpo_count 0. GPOs that point at a filter that no longer exists are listed with the filter shown as missing; such GPOs are not applied on most clients.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [filter, description, queries, gpos, gpo_count, changed]
tags: [wmi filter, wql, gpo filtering, group policy, msWMI-Som, targeting, missing filter]
source: In-box ActiveDirectory (Get-ADObject on CN=SOM,CN=WMIPolicy,CN=System msWMI-Som objects and gPCWQLFilter on groupPolicyContainer objects)
#>
param()
Invoke-Op {
    function Read-WmiQueries([string]$s) {
        # msWMI-Parm2 is '<count>;' then per query '3;<ns length>;<query length>;WQL;<namespace>;<query>;'.
        $q = @()
        try {
            $pos = 0
            $i = $s.IndexOf(';', $pos)
            $n = [int]$s.Substring($pos, $i - $pos)
            $pos = $i + 1
            for ($k = 0; $k -lt $n; $k++) {
                $f = @()
                for ($j = 0; $j -lt 4; $j++) {
                    $i = $s.IndexOf(';', $pos)
                    $f += $s.Substring($pos, $i - $pos)
                    $pos = $i + 1
                }
                $nsLen = [int]$f[1]
                $qLen = [int]$f[2]
                $ns = $s.Substring($pos, $nsLen)
                $pos += $nsLen + 1
                $text = $s.Substring($pos, $qLen)
                $pos += $qLen + 1
                $q += "$ns : $text"
            }
        } catch { $q = @("$s") }
        foreach ($x in $q) { if ($x.Length -gt 500) { $x.Substring(0, 500) } else { $x } }
    }
    $domDn = (Get-ADDomain).DistinguishedName
    $filters = @()
    try {
        $filters = @(Get-ADObject -SearchBase "CN=SOM,CN=WMIPolicy,CN=System,$domDn" -SearchScope OneLevel -LDAPFilter '(objectClass=msWMI-Som)' -Properties 'msWMI-Name', 'msWMI-Parm1', 'msWMI-Parm2', 'msWMI-ID', 'whenChanged' -ErrorAction Stop)
    } catch {
        if ("$($_.Exception.Message)" -notmatch 'Directory object not found|Cannot find an object') { throw }
    }
    $users = @{}
    foreach ($g in @(Get-ADObject -SearchBase "CN=Policies,CN=System,$domDn" -SearchScope OneLevel -LDAPFilter '(&(objectClass=groupPolicyContainer)(gPCWQLFilter=*))' -Properties displayName, gPCWQLFilter)) {
        $m = [regex]::Match("$($g.gPCWQLFilter)", '\{[0-9A-Fa-f-]{36}\}')
        if (-not $m.Success) { continue }
        $key = $m.Value.ToUpperInvariant()
        if (-not $users.ContainsKey($key)) { $users[$key] = @() }
        $users[$key] += $(if ($g.displayName) { "$($g.displayName)" } else { "$($g.Name)" })
    }
    $rows = @()
    $known = @{}
    foreach ($f in $filters) {
        $key = "$($f.'msWMI-ID')".ToUpperInvariant()
        $known[$key] = $true
        $gpos = @()
        if ($users.ContainsKey($key)) { $gpos = @($users[$key] | Sort-Object) }
        $rows += @{
            filter = "$($f.'msWMI-Name')"
            description = "$($f.'msWMI-Parm1')"
            queries = @(Read-WmiQueries "$($f.'msWMI-Parm2')")
            gpos = $gpos
            gpo_count = $gpos.Count
            changed = (Iso $f.whenChanged)
        }
    }
    foreach ($key in @($users.Keys)) {
        if ($known.ContainsKey($key)) { continue }
        $gpos = @($users[$key] | Sort-Object)
        $rows += @{ filter = "(missing filter $key)"; description = 'The GPO references a WMI filter that does not exist'; queries = @(); gpos = $gpos; gpo_count = $gpos.Count; changed = $null }
    }
    $rows = @($rows | Sort-Object { $_.filter })
    @{ items = @($rows | Select-Object -First 500); summary = @{ total = $rows.Count; filters = $filters.Count; unused = @($rows | Where-Object { $_.gpo_count -eq 0 }).Count; missing = @($rows | Where-Object { "$($_.filter)" -like '(missing filter*' }).Count; truncated = ($rows.Count -gt 500) } }
}
