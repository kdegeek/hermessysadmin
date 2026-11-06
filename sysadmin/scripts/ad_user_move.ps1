param(
    [Parameter(Mandatory)][string]$Identity,
    [Parameter(Mandatory)][string]$TargetOu
)
Invoke-Op {
    $u = Get-ADUser -Identity $Identity
    Assert-HermesNotProtected $u
    $from = Get-ParentDn $u.DistinguishedName
    Move-ADObject -Identity $u.DistinguishedName -TargetPath $TargetOu
    @{ identity = $u.SamAccountName; from = $from; to = $TargetOu }
}
