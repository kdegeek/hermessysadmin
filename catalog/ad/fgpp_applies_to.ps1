<# hermes-catalog
id: ad.fgpp_applies_to
title: Fine-grained password policy targets
category: AD hygiene
description: Each fine-grained password policy (PSO) with its precedence and every user or group it is applied to, with the group's scope and recursive member count. Flags PSOs applied to nobody and to groups that are not global security groups, which Windows ignores. The policy settings themselves are in the Password policies entry.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [policy, precedence, applies_to, class, scope, members, issue]
tags: [fine grained password policy, pso, password settings object, applies to, password policy, msds-psoappliesto]
source: In-box ActiveDirectory (Get-ADFineGrainedPasswordPolicy AppliesTo, Get-ADObject, Get-ADGroupMember -Recursive)
#>
param()
Invoke-Op {
    $errors = @()
    $rows = New-Object System.Collections.ArrayList
    foreach ($p in @(Get-ADFineGrainedPasswordPolicy -Filter * -Properties AppliesTo | Sort-Object Precedence)) {
        $targets = @($p.AppliesTo)
        if ($targets.Count -eq 0) {
            [void]$rows.Add(@{ policy = $p.Name; precedence = [int]$p.Precedence; applies_to = ''; class = ''; scope = ''; members = 0; issue = 'applied to nobody' })
            continue
        }
        foreach ($dn in $targets) {
            $o = $null
            try { $o = Get-ADObject -Identity "$dn" -Properties groupType, sAMAccountName -ErrorAction Stop } catch { }
            if (-not $o) {
                [void]$rows.Add(@{ policy = $p.Name; precedence = [int]$p.Precedence; applies_to = (Get-CnName "$dn"); class = 'unresolved'; scope = ''; members = $null; issue = 'target not found' })
                continue
            }
            $cls = "$($o.ObjectClass)"
            $scope = ''
            $members = 1
            $issue = ''
            if ($cls -eq 'group') {
                $gt = [int64]$o.groupType
                $scope = if ($gt -band 2) { 'Global' } elseif ($gt -band 4) { 'DomainLocal' } elseif ($gt -band 8) { 'Universal' } else { 'Unknown' }
                $security = (($gt -band 0x80000000) -ne 0)
                if ($scope -ne 'Global' -or -not $security) { $issue = 'not a global security group; ignored' }
                try { $members = @(Get-ADGroupMember -Identity $o.DistinguishedName -Recursive -ErrorAction Stop).Count }
                catch { $members = $null; $errors += @{ host = $o.Name; message = "$($_.Exception.Message)" } }
            }
            [void]$rows.Add(@{ policy = $p.Name; precedence = [int]$p.Precedence; applies_to = $(if ($o.sAMAccountName) { "$($o.sAMAccountName)" } else { "$($o.Name)" })
                               class = $cls; scope = $scope; members = $members; issue = $issue })
        }
    }
    $all = @($rows)
    @{ items = @($all | Select-Object -First 500); errors = $errors
       summary = @{ total = $all.Count; truncated = ($all.Count -gt 500); policies = @($all | ForEach-Object { $_['policy'] } | Sort-Object -Unique).Count
                    issues = @($all | Where-Object { $_['issue'] }).Count } }
}
