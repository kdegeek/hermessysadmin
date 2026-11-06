param(
    [Parameter(Mandatory)][string]$Group,
    [Parameter(Mandatory)][string[]]$Members,
    [switch]$Preview
)
Invoke-Op {
    $g = Get-ADGroup -Identity $Group -Properties member
    if ($Preview) {
        return @{
            summary = "Add $($Members -join ', ') to $($g.Name)"
            changes = @(foreach ($m in $Members) { "Add-ADGroupMember -Identity '$($g.Name)' -Members '$m'" })
            current = @{ member_count = @($g.member).Count; members = @($g.member | Select-Object -First 20 | ForEach-Object { Get-CnName $_ }) }
        }
    }
    Add-ADGroupMember -Identity $g -Members $Members -Confirm:$false
    @{ group = $g.Name; added = @($Members) }
}
