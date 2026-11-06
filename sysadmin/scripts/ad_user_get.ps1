param([Parameter(Mandatory)][string]$Identity)
Invoke-Op {
    $props = 'DisplayName', 'EmailAddress', 'Title', 'Department', 'Office', 'telephoneNumber', 'Description', 'Manager',
        'Enabled', 'LockedOut', 'lockoutTime', 'badPwdCount', 'PasswordLastSet', 'PasswordNeverExpires', 'PasswordExpired',
        'msDS-UserPasswordExpiryTimeComputed', 'LastLogonDate', 'whenCreated', 'whenChanged', 'MemberOf',
        'AccountExpirationDate', 'UserPrincipalName', 'CannotChangePassword'
    $u = Get-ADUser -Identity $Identity -Properties $props
    $ft = $u.'msDS-UserPasswordExpiryTimeComputed'
    $expires = $null
    if (-not $u.PasswordNeverExpires -and $ft -gt 0 -and $ft -lt [long]::MaxValue) { $expires = [datetime]::FromFileTimeUtc($ft).ToString('o') }
    @{
        sam                    = $u.SamAccountName
        name                   = $u.Name
        display_name           = $u.DisplayName
        upn                    = $u.UserPrincipalName
        dn                     = $u.DistinguishedName
        ou                     = (Get-ParentDn $u.DistinguishedName)
        email                  = $u.EmailAddress
        title                  = $u.Title
        department             = $u.Department
        office                 = $u.Office
        phone                  = $u.telephoneNumber
        description            = "$($u.Description)"
        manager                = (Get-CnName $u.Manager)
        enabled                = [bool]$u.Enabled
        locked                 = [bool]$u.LockedOut
        lockout_time           = $(if ($u.lockoutTime) { [datetime]::FromFileTimeUtc($u.lockoutTime).ToString('o') } else { $null })
        bad_password_count     = $u.badPwdCount
        password_last_set      = (Iso $u.PasswordLastSet)
        password_expires       = $expires
        password_never_expires = [bool]$u.PasswordNeverExpires
        password_expired       = [bool]$u.PasswordExpired
        cannot_change_password = [bool]$u.CannotChangePassword
        account_expires        = (Iso $u.AccountExpirationDate)
        last_logon             = (Iso $u.LastLogonDate)
        created                = (Iso $u.whenCreated)
        changed                = (Iso $u.whenChanged)
        groups                 = @($u.MemberOf | ForEach-Object { Get-CnName $_ } | Sort-Object)
    }
}
