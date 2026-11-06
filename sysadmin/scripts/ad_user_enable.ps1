param([Parameter(Mandatory)][string]$Identity)
Invoke-Op {
    $u = Get-ADUser -Identity $Identity
    Enable-ADAccount -Identity $u
    @{ identity = $u.SamAccountName; enabled = $true }
}
