param(
    [string]$Query,
    [int]$Limit = 100
)
Invoke-Op {
    $filter = '(objectClass=group)'
    if ($Query) {
        $escaped = $Query -replace '\\', '\5c' -replace '\(', '\28' -replace '\)', '\29' -replace "`0", '\00'
        $filter = "(&(objectClass=group)(anr=$escaped))"
    }
    $items = @(Get-ADGroup -LDAPFilter $filter -ResultSetSize $Limit -Properties Description, member | Sort-Object Name | ForEach-Object {
        @{
            name         = $_.Name
            sam          = $_.SamAccountName
            dn           = $_.DistinguishedName
            scope        = "$($_.GroupScope)"
            category     = "$($_.GroupCategory)"
            description  = "$($_.Description)"
            member_count = @($_.member).Count
        }
    })
    @{ items = $items; truncated = ($items.Count -ge $Limit) }
}
