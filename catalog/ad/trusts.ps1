<# hermes-catalog
id: ad.trusts
title: Domain and forest trusts
category: AD hygiene
description: Trusts defined on this domain with direction, type and attribute flags (forest transitive, selective authentication, SID filtering, intra-forest). Reachability is not tested, since that needs a second hop.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [trust_source, trust_target, direction, type, status]
tags: [trusts, forest trust, external trust, sid filtering, selective authentication, cross domain]
source: In-box ActiveDirectory (Get-ADTrust)
#>
param()
Invoke-Op {
    $rows = @(Get-ADTrust -Filter * | Sort-Object Name | ForEach-Object {
        $flags = @()
        if ($_.IntraForest) { $flags += 'intra-forest' }
        if ($_.ForestTransitive) { $flags += 'forest-transitive' }
        if ($_.SelectiveAuthentication) { $flags += 'selective-authentication' }
        if ($_.SIDFilteringQuarantined) { $flags += 'sid-filtering' }
        if ($_.DisallowTransivity) { $flags += 'non-transitive' }
        $status = 'no flags'
        if ($flags.Count -gt 0) { $status = $flags -join ', ' }
        @{ trust_source = (("$($_.Source)" -replace '(^|,)DC=', '$1') -replace ',', '.').TrimStart('.'); trust_target = "$($_.Target)"; direction = "$($_.Direction)"; type = "$($_.TrustType)"; status = $status }
    })
    @{ items = @($rows | Select-Object -First 500); summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500) } }
}
