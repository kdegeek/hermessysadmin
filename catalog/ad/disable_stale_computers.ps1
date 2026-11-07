<# hermes-catalog
id: ad.disable_stale_computers
title: Disable stale computer accounts
category: AD hygiene
description: Disables the listed computer accounts (up to 100), but only those that are still stale - no logon for at least Days days (or never, and created before then) and no machine password change in that time either. Domain controllers, protected or critical objects, failover cluster name objects, the Entra/Azure AD Seamless SSO account AZUREADSSOACC and any account holding service principal names other than the default HOST/, RestrictedKrbHost/, TERMSRV/ and WSMAN/ ones (keytab, appliance and service accounts that never log on but are in use) are refused, and accounts that do not qualify are skipped with the reason. Nothing is deleted; re-enable an account to undo. A computer that is in fact still in use loses its domain trust until it is re-enabled.
module: inbox:ActiveDirectory
target: dc
tier: H
preview: plan
columns: [name, last_logon, password_last_set, before, after, result]
tags: [stale computers, disable computers, cleanup, computer accounts, inactive, decommission, hygiene]
source: In-box ActiveDirectory (Get-ADComputer, Disable-ADAccount)
params:
  - {name: Names, type: array, required: true, description: "Computer names without the trailing $, for example PC0142. Use the Stale computer accounts entry to find candidates."}
  - {name: Days, type: integer, default: 90, minimum: 30, maximum: 3650, description: A computer qualifies only if it has neither logged on nor changed its machine password for this many days.}
#>
param([string[]]$Names = @(), [int]$Days = 90, [switch]$Preview)
Invoke-Op {
    $list = @($Names | Where-Object { $_ } | Sort-Object -Unique)
    if ($list.Count -eq 0) { throw 'InvalidArguments: Names is required.' }
    if ($list.Count -gt 100) { throw "InvalidArguments: at most 100 computers per run ($($list.Count) given)." }
    foreach ($n in $list) {
        if ($n -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9_-]{0,14}\z') { throw "InvalidArguments: '$n' must be a computer name of 1-15 letters, digits, '_' or '-', without the trailing `$." }
    }
    $cut = (Get-Date).AddDays(-$Days)
    $plan = @(foreach ($n in $list) {
        $found = @(Get-ADComputer -LDAPFilter "(sAMAccountName=$n`$)" -Properties LastLogonDate, PasswordLastSet, WhenCreated, Enabled, userAccountControl, primaryGroupID, servicePrincipalName)
        if ($found.Count -ne 1) { @{ name = $n; c = $null; reason = 'not found' }; continue }
        $c = $found[0]
        $reason = $null
        try { Assert-HermesNotProtected $c } catch { $reason = "$($_.Exception.Message)" -replace '^PolicyBlocked:\s*', '' }
        $uac = [int]$c.userAccountControl
        if (-not $reason -and (($uac -band 8192) -or ($uac -band 67108864))) { $reason = 'domain controller' }
        elseif (-not $reason -and @($c.servicePrincipalName | Where-Object { "$_" -like 'MSClusterVirtualServer/*' -or "$_" -like 'MSServerCluster/*' }).Count -gt 0) { $reason = 'failover cluster name object' }
        elseif (-not $reason -and $n -ieq 'AZUREADSSOACC') { $reason = 'Entra/Azure AD Seamless SSO account (AZUREADSSOACC); disabling it breaks Seamless SSO for every user' }
        elseif (-not $reason -and @($c.servicePrincipalName | Where-Object { "$_" -notmatch '\A(?i:HOST|RestrictedKrbHost|TERMSRV|WSMAN)/' }).Count -gt 0) {
            $extra = @($c.servicePrincipalName | Where-Object { "$_" -notmatch '\A(?i:HOST|RestrictedKrbHost|TERMSRV|WSMAN)/' } | ForEach-Object { ("$_" -split '/')[0] } | Sort-Object -Unique)
            $reason = "holds non-default service principal names ($($extra -join ', ')); it may be a keytab, appliance or service account still in use"
        }
        elseif (-not $reason -and -not $c.Enabled) { $reason = 'already disabled' }
        elseif (-not $reason -and $c.LastLogonDate -and $c.LastLogonDate -ge $cut) { $reason = "logged on $(Iso $c.LastLogonDate)" }
        elseif (-not $reason -and -not $c.LastLogonDate -and $c.WhenCreated -ge $cut) { $reason = "never logged on but created $(Iso $c.WhenCreated)" }
        elseif (-not $reason -and $c.PasswordLastSet -and $c.PasswordLastSet -ge $cut) { $reason = "machine password changed $(Iso $c.PasswordLastSet)" }
        @{ name = $n; c = $c; reason = $reason }
    })
    $go = @($plan | Where-Object { -not $_.reason })
    if ($Preview) {
        $cur = @{}
        foreach ($p in $plan) { if ($p.c) { $cur[$p.name] = @{ enabled = [bool]$p.c.Enabled; last_logon = (Iso $p.c.LastLogonDate); password_last_set = (Iso $p.c.PasswordLastSet) } } }
        return @{ summary = "Disable $($go.Count) stale computer account(s); skip $($plan.Count - $go.Count)"
                  changes = @($plan | ForEach-Object { if ($_.reason) { "$($_.name): skip ($($_.reason))" } else { "$($_.name): disable (last logon $(Iso $_.c.LastLogonDate), machine password set $(Iso $_.c.PasswordLastSet))" } })
                  current = $cur }
    }
    $rows = @(foreach ($p in $plan) {
        $ll = $null; $pls = $null
        if ($p.c) { $ll = Iso $p.c.LastLogonDate; $pls = Iso $p.c.PasswordLastSet }
        if ($p.reason) {
            @{ name = $p.name; last_logon = $ll; password_last_set = $pls; before = $(if ($p.c) { [bool]$p.c.Enabled } else { $null }); after = $(if ($p.c) { [bool]$p.c.Enabled } else { $null }); result = "skipped: $($p.reason)" }
            continue
        }
        $result = 'disabled'
        try { Disable-ADAccount -Identity $p.c.DistinguishedName -ErrorAction Stop } catch { $result = "failed: $($_.Exception.Message)" }
        $after = [bool](Get-ADComputer -Identity $p.c.ObjectGUID -Properties Enabled).Enabled
        @{ name = $p.name; last_logon = $ll; password_last_set = $pls; before = $true; after = $after; result = $result }
    })
    @{ items = $rows; summary = @{ disabled = @($rows | Where-Object { $_['result'] -eq 'disabled' }).Count
                                   skipped = @($rows | Where-Object { "$($_['result'])" -like 'skipped*' }).Count
                                   failed = @($rows | Where-Object { "$($_['result'])" -like 'failed*' }).Count; truncated = $false } }
}
