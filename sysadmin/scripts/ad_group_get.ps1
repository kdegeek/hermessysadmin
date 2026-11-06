param(
    [Parameter(Mandatory)][string]$Identity,
    [int]$Limit = 500
)
Invoke-Op {
    $g = Get-ADGroup -Identity $Identity -Properties Description, ManagedBy, member, whenChanged
    try {
        $members = @(Get-ADGroupMember -Identity $g | Select-Object -First $Limit | ForEach-Object {
            @{ name = $_.Name; sam = $_.SamAccountName; class = $_.objectClass; dn = $_.distinguishedName }
        })
    } catch {
        $members = @($g.member | Select-Object -First $Limit | ForEach-Object { @{ name = (Get-CnName $_); dn = $_ } })
    }
    @{
        name         = $g.Name
        sam          = $g.SamAccountName
        dn           = $g.DistinguishedName
        scope        = "$($g.GroupScope)"
        category     = "$($g.GroupCategory)"
        description  = "$($g.Description)"
        managed_by   = (Get-CnName $g.ManagedBy)
        member_count = @($g.member).Count
        members      = $members
        changed      = (Iso $g.whenChanged)
    }
}
