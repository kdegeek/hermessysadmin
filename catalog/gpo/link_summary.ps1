<# hermes-catalog
id: gpo.link_summary
title: GPO link summary
category: Group Policy
description: Every place each GPO is linked (domain, OU or site), with whether the link is enabled and enforced. Shows where a policy applies.
module: inbox:GroupPolicy
target: dc
tier: R
columns: [name, link_path, enabled, enforced]
tags: [gpo, group policy, links, linked, ou, enforced, scope, where applied]
source: In-box GroupPolicy (Get-GPOReport XML LinksTo)
#>
param()
Invoke-Op {
    $errs = @()
    $rows = @()
    foreach ($g in @(Get-GPO -All | Sort-Object DisplayName)) {
        try {
            $x = [xml](Get-GPOReport -Guid $g.Id -ReportType Xml)
            foreach ($l in @($x.GPO.LinksTo | Where-Object { $_ })) {
                $rows += @{ name = $g.DisplayName; link_path = "$($l.SOMPath)"; enabled = ("$($l.Enabled)" -eq 'true'); enforced = ("$($l.NoOverride)" -eq 'true') }
            }
        } catch { $errs += @{ host = $env:COMPUTERNAME; message = "$($g.DisplayName): $($_.Exception.Message)" } }
    }
    @{ items = @($rows | Select-Object -First 500); errors = $errs; summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500) } }
}
