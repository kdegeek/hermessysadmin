<# hermes-catalog
id: gpo.broken
title: Broken GPOs
category: Group Policy
description: GPOs that exist in Active Directory but have no folder in SYSVOL, SYSVOL folders with no matching GPO in Active Directory, and policy folders missing GPT.INI. Compares AD with the local domain controller's SYSVOL.
module: inbox:GroupPolicy
target: dc
tier: R
columns: [name, status, domain]
tags: [gpo, group policy, broken, orphaned, sysvol, missing, corrupt, gpt.ini]
source: In-box ActiveDirectory and local SYSVOL file reads
#>
param()
Invoke-Op {
    $dom = Get-ADDomain
    $pol = Get-HermesSysvolPath -Child Policies
    $adGpos = @(Get-ADObject -SearchBase "CN=Policies,CN=System,$($dom.DistinguishedName)" -SearchScope OneLevel -LDAPFilter '(objectClass=groupPolicyContainer)' -Properties displayName)
    $folders = @(Get-ChildItem -LiteralPath $pol -Directory -ErrorAction Stop | Where-Object { $_.Name -match '^\{[0-9A-Fa-f-]{36}\}$' })
    $folderNames = @{}
    foreach ($f in $folders) { $folderNames[$f.Name.ToUpperInvariant()] = $f.FullName }
    $adNames = @{}
    $rows = @()
    foreach ($o in $adGpos) {
        $key = "$($o.Name)".ToUpperInvariant()
        $adNames[$key] = $true
        $label = if ($o.displayName) { "$($o.displayName)" } else { "$($o.Name)" }
        if (-not $folderNames.ContainsKey($key)) {
            $rows += @{ name = $label; status = 'In Active Directory but missing from SYSVOL'; domain = $dom.DNSRoot }
        } elseif (-not (Test-Path -LiteralPath (Join-Path $folderNames[$key] 'GPT.INI'))) {
            $rows += @{ name = $label; status = 'SYSVOL folder is missing GPT.INI'; domain = $dom.DNSRoot }
        }
    }
    foreach ($f in $folders) {
        if (-not $adNames.ContainsKey($f.Name.ToUpperInvariant())) {
            $rows += @{ name = $f.Name; status = 'In SYSVOL but missing from Active Directory'; domain = $dom.DNSRoot }
        }
    }
    $rows = @($rows | Sort-Object { $_.name })
    @{ items = @($rows | Select-Object -First 500); summary = @{ total = $rows.Count; ad_gpos = $adGpos.Count; sysvol_folders = $folders.Count; truncated = ($rows.Count -gt 500) } }
}
