param(
    [Parameter(Mandatory)][string]$Identity,
    [string]$Password,
    [bool]$MustChange = $true,
    [bool]$Unlock = $true
)
Invoke-Op {
    $u = Get-ADUser -Identity $Identity -Properties LockedOut
    Assert-HermesNotProtected $u
    $generated = -not $Password
    if ($generated) { $Password = New-HermesPassword }
    Set-ADAccountPassword -Identity $u -Reset -NewPassword (ConvertTo-HermesSecure $Password)
    # The password is changed: nothing below may throw, or the one-time password would be lost.
    $warnings = @()
    try { Set-ADUser -Identity $u -ChangePasswordAtLogon $MustChange }
    catch { $warnings += "Could not set 'must change at next logon': $($_.Exception.Message)" }
    $unlocked = $false
    if ($Unlock -and $u.LockedOut) {
        try { Unlock-ADAccount -Identity $u; $unlocked = $true }
        catch { $warnings += "Could not unlock: $($_.Exception.Message)" }
    }
    $out = @{ identity = $u.SamAccountName; must_change = $MustChange; unlocked = $unlocked; warnings = $warnings; password_source = $(if ($generated) { 'generated' } else { 'provided' }) }
    if ($generated) { $out.password = $Password }
    $out
}
