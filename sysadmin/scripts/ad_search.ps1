param(
    [Parameter(Mandatory)][string]$Query,
    [ValidateSet('any', 'user', 'group', 'computer', 'ou')][string]$Kind = 'any',
    [int]$Limit = 25
)
Invoke-Op {
    if ($Query.TrimStart().StartsWith('(')) {
        $filter = $Query
    } else {
        $escaped = $Query -replace '\\', '\5c' -replace '\(', '\28' -replace '\)', '\29' -replace "`0", '\00'
        $filter = "(anr=$escaped)"
    }
    $classFilter = switch ($Kind) {
        'user' { '(&(objectCategory=person)(objectClass=user))' }
        'group' { '(objectClass=group)' }
        'computer' { '(objectClass=computer)' }
        'ou' { '(objectClass=organizationalUnit)' }
        default { $null }
    }
    if ($classFilter) { $filter = "(&$classFilter$filter)" }
    $items = @(Get-ADObject -LDAPFilter $filter -ResultSetSize $Limit -Properties sAMAccountName, displayName, description, whenChanged | ForEach-Object {
        @{
            name         = $_.Name
            dn           = $_.DistinguishedName
            class        = $_.ObjectClass
            sam          = $_.sAMAccountName
            display_name = $_.displayName
            description  = "$($_.description)"
            changed      = (Iso $_.whenChanged)
        }
    })
    @{ items = $items; filter = $filter; truncated = ($items.Count -ge $Limit) }
}
