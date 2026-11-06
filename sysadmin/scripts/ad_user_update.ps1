param(
    [Parameter(Mandatory)][string]$Identity,
    [string]$DisplayName,
    [string]$GivenName,
    [string]$Surname,
    [string]$Email,
    [string]$Title,
    [string]$Department,
    [string]$Office,
    [string]$Phone,
    [string]$Description,
    [string]$Manager
)
Invoke-Op {
    $map = [ordered]@{
        DisplayName = $DisplayName; GivenName = $GivenName; Surname = $Surname; EmailAddress = $Email
        Title = $Title; Department = $Department; Office = $Office; OfficePhone = $Phone; Description = $Description
    }
    $u = Get-ADUser -Identity $Identity
    Assert-HermesNotProtected $u
    $splat = @{ Identity = $Identity }
    foreach ($k in $map.Keys) { if ($map[$k]) { $splat[$k] = $map[$k] } }
    if ($Manager) { $splat.Manager = (Get-ADUser -Identity $Manager).DistinguishedName }
    Assert-Hermes ($splat.Count -gt 1) 'Give at least one attribute to change.'
    Set-ADUser @splat
    @{ identity = $Identity; changed = @($splat.Keys | Where-Object { $_ -ne 'Identity' } | Sort-Object) }
}
