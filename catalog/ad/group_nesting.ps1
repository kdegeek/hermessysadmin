<# hermes-catalog
id: ad.group_nesting
title: Deep and circular group nesting
category: AD hygiene
description: Groups in this domain that sit at least MinDepth levels deep in a chain of nested groups (the longest chain of groups it is a member of), with that chain, plus groups that are part of a circular nesting loop. Deep or circular nesting makes effective access hard to reason about and slows token building. Membership in groups from other domains is not followed.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [group, depth, circular, chain]
tags: [group nesting, nested groups, circular nesting, recursive groups, token bloat, group hygiene]
source: In-box ActiveDirectory (Get-ADGroup memberOf)
params:
  - {name: MinDepth, type: integer, default: 3, minimum: 1, maximum: 50, description: List groups nested at least this many levels deep.}
#>
param([int]$MinDepth = 3)
Invoke-Op {
    $groups = @(Get-ADGroup -Filter * -Properties MemberOf)
    $parents = @{}
    $names = @{}
    foreach ($g in $groups) {
        $k = $g.DistinguishedName.ToLowerInvariant()
        $names[$k] = $g.Name
        $parents[$k] = @($g.MemberOf | ForEach-Object { "$_".ToLowerInvariant() })
    }
    $state = @{}
    $depth = @{}
    $next = @{}
    $cyclic = @{}
    # Iterative depth-first walk (no recursion limit): longest chain upwards through memberOf, back edges mark loops.
    foreach ($start in @($parents.Keys)) {
        if ($state[$start] -eq 2) { continue }
        $stack = New-Object System.Collections.Stack
        $stack.Push(@($start, 0))
        $state[$start] = 1
        while ($stack.Count -gt 0) {
            $frame = $stack.Pop()
            $node = $frame[0]; $i = [int]$frame[1]
            $ps = @($parents[$node] | Where-Object { $parents.ContainsKey($_) })
            if ($i -lt $ps.Count) {
                $stack.Push(@($node, ($i + 1)))
                $p = $ps[$i]
                if ($state[$p] -eq 1) { $cyclic[$p] = $true; $cyclic[$node] = $true }
                elseif ($state[$p] -ne 2) { $state[$p] = 1; $stack.Push(@($p, 0)) }
                continue
            }
            $best = 0; $bestP = $null
            foreach ($p in $ps) {
                if ($state[$p] -eq 2 -and ($depth[$p] + 1) -gt $best) { $best = $depth[$p] + 1; $bestP = $p }
            }
            $depth[$node] = $best; $next[$node] = $bestP; $state[$node] = 2
        }
    }
    $rows = @(foreach ($k in @($parents.Keys)) {
        $d = [int]$depth[$k]
        $isCyc = $cyclic.ContainsKey($k)
        if ($d -lt $MinDepth -and -not $isCyc) { continue }
        $chain = @($names[$k])
        $cur = $next[$k]
        $hops = 0
        while ($cur -and $hops -lt 20) { $chain += $names[$cur]; $cur = $next[$cur]; $hops++ }
        @{ group = $names[$k]; depth = $d; circular = $isCyc; chain = ($chain -join ' > ') }
    })
    $rows = @($rows | Sort-Object { -[int]$_['depth'] }, { $_['group'] })
    @{ items = @($rows | Select-Object -First 500)
       summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); groups = $groups.Count; circular = $cyclic.Count; min_depth = $MinDepth
                    max_depth = $(if ($rows.Count) { [int]$rows[0]['depth'] } else { 0 }) } }
}
