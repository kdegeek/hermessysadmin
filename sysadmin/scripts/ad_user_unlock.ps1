param([Parameter(Mandatory)][string]$Identity)
Invoke-Op {
    $u = Get-ADUser -Identity $Identity -Properties LockedOut
    Assert-HermesNotProtected $u
    if ($u.LockedOut) { Unlock-ADAccount -Identity $u }
    @{ identity = $u.SamAccountName; was_locked = [bool]$u.LockedOut; locked = $false }
}
