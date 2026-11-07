<# hermes-catalog
id: ad.managed_service_accounts
title: Managed service accounts
category: AD hygiene
description: Group, standalone and delegated managed service accounts with enabled state, the computers they are linked to, which principals may retrieve the managed password (names only; the password itself is never read), SPNs, password change interval, creation date and last logon. The summary counts the KDS root keys that group managed service accounts need (key names and dates only).
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [name, type, enabled, hosts, allowed_principals, spns, password_interval_days, created, last_logon]
tags: [gmsa, msa, smsa, dmsa, managed service account, service accounts, kds root key, principalsallowedtoretrievemanagedpassword]
source: In-box ActiveDirectory (Get-ADServiceAccount, Get-ADObject on the Master Root Keys container)
#>
param()
Invoke-Op {
    $errors = @()
    $props = @('Enabled', 'HostComputers', 'PrincipalsAllowedToRetrieveManagedPassword', 'ServicePrincipalNames', 'whenCreated', 'LastLogonDate', 'msDS-ManagedPasswordInterval')
    $types = @{ 'msDS-GroupManagedServiceAccount' = 'gMSA'; 'msDS-ManagedServiceAccount' = 'sMSA'; 'msDS-DelegatedManagedServiceAccount' = 'dMSA' }
    $rows = @(Get-ADServiceAccount -Filter * -Properties $props | Sort-Object Name | ForEach-Object {
        $cls = "$($_.ObjectClass)"
        @{ name = $_.SamAccountName; type = $(if ($types.ContainsKey($cls)) { $types[$cls] } else { $cls }); enabled = [bool]$_.Enabled
           hosts = (@($_.HostComputers | Select-Object -First 20 | ForEach-Object { Get-CnName "$_" }) -join ', ')
           allowed_principals = (@($_.PrincipalsAllowedToRetrieveManagedPassword | Select-Object -First 20 | ForEach-Object { Get-CnName "$_" }) -join ', ')
           spns = (@($_.ServicePrincipalNames | Select-Object -First 10) -join ', ')
           password_interval_days = $_.'msDS-ManagedPasswordInterval'
           created = (Iso $_.whenCreated); last_logon = (Iso $_.LastLogonDate) }
    })
    $kds = $null
    $kdsNewest = $null
    try {
        $config = "$((Get-ADRootDSE).configurationNamingContext)"
        $keys = @(Get-ADObject -SearchBase "CN=Master Root Keys,CN=Group Key Distribution Service,CN=Services,$config" -SearchScope OneLevel -Filter * -Properties whenCreated -ErrorAction Stop)
        $kds = $keys.Count
        if ($keys.Count -gt 0) { $kdsNewest = Iso (($keys | Sort-Object whenCreated -Descending | Select-Object -First 1).whenCreated) }
    } catch { $errors += @{ host = 'KDS root keys'; message = "$($_.Exception.Message)" } }
    @{ items = @($rows | Select-Object -First 500); errors = $errors
       summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); kds_root_keys = $kds; kds_newest_key = $kdsNewest
                    unlinked = @($rows | Where-Object { -not $_['hosts'] -and -not $_['allowed_principals'] }).Count } }
}
