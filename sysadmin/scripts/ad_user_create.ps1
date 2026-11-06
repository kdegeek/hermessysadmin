param(
    [Parameter(Mandatory)][string]$Sam,
    [string]$GivenName,
    [string]$Surname,
    [string]$DisplayName,
    [string]$Path,
    [string]$Template,
    [string]$Email,
    [string]$Title,
    [string]$Department,
    [string]$Description,
    [string]$Password,
    [bool]$MustChange = $true,
    [bool]$Enabled = $true,
    [string[]]$PrivilegedGroups = @()
)
Invoke-Op {
    $tpl = $null
    if ($Template) {
        $tpl = Get-ADUser -Identity $Template -Properties MemberOf, Department
        if (-not $Path) { $Path = Get-ParentDn $tpl.DistinguishedName }
        if (-not $Department) { $Department = $tpl.Department }
    }
    Assert-Hermes ([bool]$Path) 'Give an OU (ou) or a template user to copy the OU from.'
    $domain = Get-ADDomain
    if (-not $DisplayName) { $DisplayName = (@($GivenName, $Surname) | Where-Object { $_ }) -join ' ' }
    if (-not $DisplayName) { $DisplayName = $Sam }
    $generated = -not $Password
    if ($generated) { $Password = New-HermesPassword }
    $splat = @{
        Name                  = $DisplayName
        SamAccountName        = $Sam
        UserPrincipalName     = "$Sam@$($domain.DNSRoot)"
        DisplayName           = $DisplayName
        Path                  = $Path
        AccountPassword       = (ConvertTo-HermesSecure $Password)
        Enabled               = $Enabled
        ChangePasswordAtLogon = $MustChange
        PassThru              = $true
    }
    foreach ($pair in @(@('GivenName', $GivenName), @('Surname', $Surname), @('EmailAddress', $Email), @('Title', $Title), @('Department', $Department), @('Description', $Description))) {
        if ($pair[1]) { $splat[$pair[0]] = $pair[1] }
    }
    $u = New-ADUser @splat
    # The account now exists: nothing below may throw, or the one-time password would be lost.
    $copied = @()
    $skipped = @()
    $failed = @()
    if ($tpl) {
        $deny = @($PrivilegedGroups | ForEach-Object { "$_".ToLower() })
        foreach ($g in @($tpl.MemberOf)) {
            $cn = Get-CnName $g
            if ($deny -contains $cn.ToLower()) { $skipped += $cn; continue }
            try {
                Add-ADGroupMember -Identity $g -Members $u.SamAccountName
                $copied += $cn
            } catch { $failed += @{ group = $cn; error = "$($_.Exception.Message)" } }
        }
    }
    $out = @{
        sam             = $u.SamAccountName
        dn              = $u.DistinguishedName
        upn             = $u.UserPrincipalName
        enabled         = $Enabled
        must_change     = $MustChange
        groups_copied   = $copied
        groups_skipped  = $skipped
        groups_failed   = $failed
        password_source = $(if ($generated) { 'generated' } else { 'provided' })
    }
    if ($generated) { $out.password = $Password }
    $out
}
