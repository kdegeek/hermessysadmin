param(
    [string]$Query,
    [string]$SearchBase,
    [ValidateSet('any', 'enabled', 'disabled', 'locked')][string]$Status = 'any',
    [ValidateSet('any', 'expired', 'expiring', 'never_expires')][string]$Password = 'any',
    [int]$StaleDays = 0,
    [int]$ExpiringDays = 7,
    [bool]$Privileged = $false,
    [int]$Limit = 200
)
Invoke-Op {
    $parts = @('(objectCategory=person)', '(objectClass=user)')
    if ($Status -eq 'disabled') { $parts += '(userAccountControl:1.2.840.113556.1.4.803:=2)' }
    if ($Status -eq 'enabled') { $parts += '(!(userAccountControl:1.2.840.113556.1.4.803:=2))' }
    if ($Password -eq 'never_expires') { $parts += '(userAccountControl:1.2.840.113556.1.4.803:=65536)' }
    if ($Query) {
        $escaped = $Query -replace '\\', '\5c' -replace '\(', '\28' -replace '\)', '\29' -replace "`0", '\00'
        $parts += "(anr=$escaped)"
    }
    $splat = @{
        LDAPFilter = '(&' + ($parts -join '') + ')'
        Properties = @('DisplayName', 'EmailAddress', 'Title', 'Department', 'Enabled', 'LockedOut', 'PasswordLastSet',
            'PasswordNeverExpires', 'PasswordExpired', 'msDS-UserPasswordExpiryTimeComputed', 'LastLogonDate', 'MemberOf')
    }
    if ($SearchBase) { $splat.SearchBase = $SearchBase }
    $nowUtc = (Get-Date).ToUniversalTime()
    $staleCutoff = (Get-Date).AddDays(-$StaleDays)
    $rows = @(foreach ($u in @(Get-ADUser @splat | Sort-Object Name)) {
        $ft = $u.'msDS-UserPasswordExpiryTimeComputed'
        $exp = $null
        if (-not $u.PasswordNeverExpires -and $ft -gt 0 -and $ft -lt [long]::MaxValue) { $exp = [datetime]::FromFileTimeUtc($ft) }
        if ($Status -eq 'locked' -and -not $u.LockedOut) { continue }
        if ($Password -eq 'expired' -and -not ($u.PasswordExpired -or ($exp -and $exp -lt $nowUtc))) { continue }
        if ($Password -eq 'expiring' -and -not ($exp -and $exp -gt $nowUtc -and $exp -lt $nowUtc.AddDays($ExpiringDays))) { continue }
        if ($StaleDays -gt 0 -and $u.LastLogonDate -and $u.LastLogonDate -gt $staleCutoff) { continue }
        @{
            sam                    = $u.SamAccountName
            name                   = $u.Name
            display_name           = $u.DisplayName
            dn                     = $u.DistinguishedName
            ou                     = (Get-ParentDn $u.DistinguishedName)
            enabled                = [bool]$u.Enabled
            locked                 = [bool]$u.LockedOut
            last_logon             = (Iso $u.LastLogonDate)
            password_last_set      = (Iso $u.PasswordLastSet)
            password_expires       = $(if ($exp) { $exp.ToString('o') } else { $null })
            password_never_expires = [bool]$u.PasswordNeverExpires
            password_expired       = [bool]($u.PasswordExpired -or ($exp -and $exp -lt $nowUtc))
            email                  = $u.EmailAddress
            title                  = $u.Title
            department             = $u.Department
            groups                 = @($u.MemberOf | ForEach-Object { Get-CnName $_ })
        }
    })
    $total = $rows.Count
    if (-not $Privileged -and $rows.Count -gt $Limit) { $rows = @($rows[0..($Limit - 1)]) }
    @{ items = $rows; total = $total; limit = $Limit }
}
