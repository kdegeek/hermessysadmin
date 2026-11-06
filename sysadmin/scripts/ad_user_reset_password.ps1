param(
    [Parameter(Mandatory)][string]$Identity,
    [string]$Password,
    [bool]$MustChange = $true,
    [bool]$Unlock = $true
)
Invoke-Op {
    $u = Get-ADUser -Identity $Identity -Properties LockedOut
    $generated = -not $Password
    if ($generated) { $Password = New-HermesPassword }
    Set-ADAccountPassword -Identity $u -Reset -NewPassword (ConvertTo-HermesSecure $Password)
    Set-ADUser -Identity $u -ChangePasswordAtLogon $MustChange
    $unlocked = $false
    if ($Unlock -and $u.LockedOut) {
        Unlock-ADAccount -Identity $u
        $unlocked = $true
    }
    $out = @{ identity = $u.SamAccountName; must_change = $MustChange; unlocked = $unlocked; password_source = $(if ($generated) { 'generated' } else { 'provided' }) }
    if ($generated) { $out.password = $Password }
    $out
}
