<# hermes-catalog
id: sessions.user_last_logon
title: Exact last logon of a user per DC
category: Users & sessions
description: For one user, the non-replicated lastLogon, logon count, bad password count and time of the last bad password as recorded on each domain controller, plus the newest logon across all of them. More exact than the replicated LastLogonDate, which can lag by two weeks. DCs that cannot be queried are listed under errors.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [dc, site, last_logon, logon_count, bad_password_count, last_bad_password]
tags: [last logon, lastlogon, exact last logon, per dc, bad password, badpwdcount, user activity, when did user log on]
source: In-box ActiveDirectory (Get-ADUser -Server against each Get-ADDomainController)
params:
  - {name: Identity, type: string, required: true, description: The user's sAMAccountName or userPrincipalName.}
#>
param([string]$Identity)
Invoke-Op {
    if ($Identity -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._@-]{0,255}\z') { throw "InvalidArguments: Identity must be a sAMAccountName or UPN (letters, digits, '.', '_', '@' or '-', up to 256 characters)" }
    $v = ConvertTo-LdapValue $Identity
    $found = @(Get-ADUser -LDAPFilter "(|(sAMAccountName=$v)(userPrincipalName=$v))")
    if ($found.Count -eq 0) { throw "Cannot find a user with identity '$Identity'." }
    if ($found.Count -gt 1) { throw "Identity '$Identity' matches $($found.Count) users; use the sAMAccountName." }
    $dn = $found[0].DistinguishedName
    $errors = @()
    $newest = $null
    $rows = @(foreach ($dc in @(Get-ADDomainController -Filter * | Sort-Object HostName)) {
        try {
            $u = Get-ADUser -Identity $dn -Server $dc.HostName -Properties lastLogon, logonCount, badPwdCount, badPasswordTime -ErrorAction Stop
        } catch { $errors += @{ host = $dc.HostName; message = "$($_.Exception.Message)" }; continue }
        $ll = $null
        if ($u.lastLogon -and [int64]$u.lastLogon -gt 0) {
            $t = [datetime]::FromFileTimeUtc([int64]$u.lastLogon)
            $ll = $t.ToString('o')
            if ($null -eq $newest -or $t -gt $newest) { $newest = $t }
        }
        $bad = $null
        if ($u.badPasswordTime -and [int64]$u.badPasswordTime -gt 0) { $bad = [datetime]::FromFileTimeUtc([int64]$u.badPasswordTime).ToString('o') }
        @{ dc = $dc.HostName; site = $dc.Site; last_logon = $ll; logon_count = $u.logonCount; bad_password_count = $u.badPwdCount; last_bad_password = $bad }
    })
    @{ items = $rows; errors = $errors
       summary = @{ user = $found[0].SamAccountName; total = $rows.Count; truncated = $false; dcs_failed = $errors.Count
                    last_logon = $(if ($newest) { $newest.ToString('o') } else { $null }) } }
}
