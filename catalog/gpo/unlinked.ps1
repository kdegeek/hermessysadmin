<# hermes-catalog
id: gpo.unlinked
title: Unlinked GPOs
category: Group Policy
description: Group Policy objects that are not linked to any site, domain or OU, so they currently apply to nothing. Candidates for review or cleanup.
module: inbox:GroupPolicy
target: dc
tier: R
columns: [name, modified]
tags: [gpo, group policy, unlinked, unused, orphaned, cleanup, hygiene]
source: In-box GroupPolicy (Get-GPO, Get-GPOReport)
#>
param()
Invoke-Op {
    $dcName = Get-HermesDc
    $errs = @()
    $rows = @()
    foreach ($g in @(Get-GPO -All)) {
        try {
            $x = [xml](Get-GPOReport -Guid $g.Id -ReportType Xml)
            $links = @($x.GPO.LinksTo | Where-Object { $_ })
            if ($links.Count -eq 0) { $rows += @{ name = $g.DisplayName; modified = (Iso $g.ModificationTime) } }
        } catch { $errs += @{ host = $dcName; message = "$($g.DisplayName): $($_.Exception.Message)" } }
    }
    $rows = @($rows | Sort-Object { $_.name })
    @{ items = @($rows | Select-Object -First 500); errors = $errs; summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500) } }
}
