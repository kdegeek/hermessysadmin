<# hermes-catalog
id: ad.forest_settings
title: Forest and domain settings
category: AD hygiene
description: Forest-wide and domain-wide settings that are easy to forget, one per row with a note - forest and domain functional levels, schema version and the Windows release it matches, tombstone and deleted-object lifetimes, AD Recycle Bin and Privileged Access Management features, the machine account quota (how many computers any user may join), dSHeuristics (including anonymous LDAP access), UPN suffixes and counts of sites, domains and global catalogs.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [setting, value, note]
tags: [functional level, schema version, tombstone lifetime, recycle bin, machine account quota, dsheuristics, upn suffix, forest, domain settings]
source: In-box ActiveDirectory (Get-ADForest, Get-ADDomain, Get-ADRootDSE, Get-ADObject, Get-ADOptionalFeature)
#>
param()
Invoke-Op {
    $f = Get-ADForest
    $d = Get-ADDomain
    $rootDse = Get-ADRootDSE
    $config = "$($rootDse.configurationNamingContext)"
    $errors = @()
    $rows = New-Object System.Collections.ArrayList
    [void]$rows.Add(@{ setting = 'forest_mode'; value = "$($f.ForestMode)"; note = "Forest $($f.Name)" })
    [void]$rows.Add(@{ setting = 'domain_mode'; value = "$($d.DomainMode)"; note = "Domain $($d.DNSRoot)" })

    $schemaNames = @{ 13 = 'Windows 2000'; 30 = 'Windows Server 2003'; 31 = 'Windows Server 2003 R2'; 44 = 'Windows Server 2008'; 47 = 'Windows Server 2008 R2'
                      56 = 'Windows Server 2012'; 69 = 'Windows Server 2012 R2'; 87 = 'Windows Server 2016'; 88 = 'Windows Server 2019 or 2022'; 91 = 'Windows Server 2025' }
    try {
        $sv = [int](Get-ADObject -Identity "$($rootDse.schemaNamingContext)" -Properties objectVersion -ErrorAction Stop).objectVersion
        $sn = if ($schemaNames.ContainsKey($sv)) { $schemaNames[$sv] } else { 'unrecognised version' }
        [void]$rows.Add(@{ setting = 'schema_version'; value = $sv; note = $sn })
    } catch { $errors += @{ host = 'schema'; message = "$($_.Exception.Message)" } }

    try {
        $ds = Get-ADObject -Identity "CN=Directory Service,CN=Windows NT,CN=Services,$config" -Properties tombstoneLifetime, 'msDS-DeletedObjectLifetime', dSHeuristics -ErrorAction Stop
        $tsl = $ds.tombstoneLifetime
        [void]$rows.Add(@{ setting = 'tombstone_lifetime_days'; value = $(if ($tsl) { [int]$tsl } else { 60 })
                           note = $(if ($tsl) { 'Set explicitly' } else { 'Not set, so the 60 day default applies' }) })
        $dol = $ds.'msDS-DeletedObjectLifetime'
        [void]$rows.Add(@{ setting = 'deleted_object_lifetime_days'; value = $(if ($dol) { [int]$dol } else { $(if ($tsl) { [int]$tsl } else { 60 }) })
                           note = $(if ($dol) { 'Set explicitly' } else { 'Not set, so it equals the tombstone lifetime' }) })
        $h = "$($ds.dSHeuristics)"
        $anon = ($h.Length -ge 7 -and $h[6] -eq '2')
        [void]$rows.Add(@{ setting = 'dsheuristics'; value = $h
                           note = $(if ($anon) { 'Anonymous LDAP operations are allowed (7th character is 2)' } elseif ($h) { 'Non-default value; review each character' } else { 'Default' }) })
    } catch { $errors += @{ host = 'Directory Service'; message = "$($_.Exception.Message)" } }

    foreach ($feat in @('Recycle Bin Feature', 'Privileged Access Management Feature')) {
        try {
            $o = @(Get-ADOptionalFeature -Filter "Name -eq '$feat'" -ErrorAction Stop)
            $on = ($o.Count -gt 0 -and @($o[0].EnabledScopes).Count -gt 0)
            $key = if ($feat -like 'Recycle*') { 'recycle_bin_enabled' } else { 'pam_feature_enabled' }
            [void]$rows.Add(@{ setting = $key; value = $on; note = $(if ($o.Count -eq 0) { 'Feature not available at this forest level' } elseif ($on) { 'Enabled (cannot be disabled)' } else { 'Not enabled' }) })
        } catch { $errors += @{ host = $feat; message = "$($_.Exception.Message)" } }
    }

    try {
        $q = (Get-ADObject -Identity $d.DistinguishedName -Properties 'ms-DS-MachineAccountQuota' -ErrorAction Stop).'ms-DS-MachineAccountQuota'
        [void]$rows.Add(@{ setting = 'machine_account_quota'; value = $q
                           note = $(if ([int]$q -gt 0) { "Any authenticated user can join up to $q computers to the domain" } else { 'Only delegated accounts can join computers' }) })
    } catch { $errors += @{ host = 'machine account quota'; message = "$($_.Exception.Message)" } }

    [void]$rows.Add(@{ setting = 'upn_suffixes'; value = (@($f.UPNSuffixes) -join ', '); note = 'Alternative UPN suffixes defined on the forest' })
    [void]$rows.Add(@{ setting = 'domains'; value = @($f.Domains).Count; note = (@($f.Domains) -join ', ') })
    [void]$rows.Add(@{ setting = 'sites'; value = @($f.Sites).Count; note = '' })
    [void]$rows.Add(@{ setting = 'global_catalogs'; value = @($f.GlobalCatalogs).Count; note = (@($f.GlobalCatalogs | Select-Object -First 20) -join ', ') })
    $all = @($rows)
    @{ items = $all; errors = $errors; summary = @{ total = $all.Count; truncated = $false } }
}
