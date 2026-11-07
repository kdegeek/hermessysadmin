<# hermes-catalog
id: ad.kerberos_encryption
title: Weak Kerberos encryption types
category: AD hygiene
description: User, computer and service accounts whose Kerberos encryption settings allow only weak ciphers - the "use DES key only" flag, DES enabled in msDS-SupportedEncryptionTypes, or RC4 without any AES type. The summary also counts user accounts with SPNs that have no encryption types set, which older domain controllers serve with RC4 tickets. Only the setting is read, never a key.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [name, class, enabled, enc_types, has_spn, issue]
tags: [kerberos, encryption types, rc4, des, aes, msds-supportedencryptiontypes, use des key only, weak crypto, hardening]
source: In-box ActiveDirectory (Get-ADObject LDAP filter on msDS-SupportedEncryptionTypes and userAccountControl)
#>
param()
Invoke-Op {
    $names = @{ 1 = 'DES-CBC-CRC'; 2 = 'DES-CBC-MD5'; 4 = 'RC4'; 8 = 'AES128'; 16 = 'AES256' }
    $filter = '(&(objectClass=user)(|(msDS-SupportedEncryptionTypes=*)(userAccountControl:1.2.840.113556.1.4.803:=2097152)))'
    $rows = @(Get-ADObject -LDAPFilter $filter -Properties 'msDS-SupportedEncryptionTypes', userAccountControl, sAMAccountName, servicePrincipalName | ForEach-Object {
        $uac = [int]$_.userAccountControl
        $et = 0
        if ($null -ne $_.'msDS-SupportedEncryptionTypes') { $et = [int]$_.'msDS-SupportedEncryptionTypes' }
        $issues = @()
        if ($uac -band 2097152) { $issues += 'use DES key only flag set' }
        if ($et -band 3) { $issues += 'DES enabled' }
        if (($et -band 4) -and -not ($et -band 24)) { $issues += 'RC4 without AES' }
        if ($issues.Count -eq 0) { return }
        $types = @(foreach ($bit in @(1, 2, 4, 8, 16)) { if ($et -band $bit) { $names[$bit] } })
        @{ name = "$($_.sAMAccountName)"; class = "$($_.ObjectClass)"; enabled = -not ($uac -band 2)
           enc_types = "$et ($($types -join ', '))"; has_spn = (@($_.servicePrincipalName).Count -gt 0); issue = ($issues -join '; ') }
    })
    $rows = @($rows | Sort-Object { $_['name'] })
    $unset = $null
    try {
        $unset = @(Get-ADUser -LDAPFilter '(&(objectCategory=person)(objectClass=user)(servicePrincipalName=*)(!(msDS-SupportedEncryptionTypes=*))(!(userAccountControl:1.2.840.113556.1.4.803:=2)))').Count
    } catch { $unset = $null }
    @{ items = @($rows | Select-Object -First 500)
       summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); spn_users_without_enc_types = $unset
                    des = @($rows | Where-Object { $_['issue'] -like '*DES*' }).Count; rc4_only = @($rows | Where-Object { $_['issue'] -like '*RC4 without AES*' }).Count } }
}
