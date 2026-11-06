param([Parameter(Mandatory)][string]$Identity)
Invoke-Op {
    $u = Get-ADUser -Identity $Identity
    Assert-HermesNotProtected $u
    Enable-ADAccount -Identity $u
    @{ identity = $u.SamAccountName; enabled = $true }
}
