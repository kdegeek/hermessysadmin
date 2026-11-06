param(
    [ValidateSet('any', 'user', 'group', 'computer', 'ou')][string]$Kind = 'any',
    [string]$Query,
    [int]$Limit = 100
)
Invoke-Op {
    $classes = @{ user = 'user'; group = 'group'; computer = 'computer'; ou = 'organizationalUnit' }
    $items = @(Get-ADObject -Filter 'isDeleted -eq $true' -IncludeDeletedObjects -Properties 'msDS-LastKnownRDN', lastKnownParent, whenChanged, sAMAccountName |
        Where-Object { $_.Name -ne 'Deleted Objects' } |
        Where-Object { $Kind -eq 'any' -or $_.ObjectClass -eq $classes[$Kind] } |
        Where-Object { -not $Query -or "$($_.'msDS-LastKnownRDN')" -like "*$Query*" -or "$($_.sAMAccountName)" -like "*$Query*" } |
        Sort-Object whenChanged -Descending |
        Select-Object -First $Limit |
        ForEach-Object {
            @{
                guid              = "$($_.ObjectGUID)"
                name              = "$($_.'msDS-LastKnownRDN')"
                sam               = $_.sAMAccountName
                class             = $_.ObjectClass
                last_known_parent = $_.lastKnownParent
                deleted           = (Iso $_.whenChanged)
            }
        })
    @{ items = $items }
}
