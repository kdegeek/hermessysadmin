param(
    [Parameter(Mandatory)][string]$Identity,
    [string]$Note
)
Invoke-Op {
    $u = Get-ADUser -Identity $Identity
    Disable-ADAccount -Identity $u
    if ($Note) { Set-ADUser -Identity $u -Description $Note }
    @{ identity = $u.SamAccountName; enabled = $false; note = $Note }
}
