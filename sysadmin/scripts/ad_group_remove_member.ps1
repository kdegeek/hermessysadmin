param(
    [Parameter(Mandatory)][string]$Group,
    [Parameter(Mandatory)][string[]]$Members,
    [switch]$Preview
)
Invoke-Op {
    $g = Get-ADGroup -Identity $Group -Properties member
    # Resolve once, check the resolved objects, then change exactly those objects (by DN).
    $resolved = @(foreach ($m in $Members) { Resolve-HermesMember $m })
    foreach ($r in $resolved) { Assert-HermesNotProtected $r -AsMember }
    $dns = @($resolved | ForEach-Object { $_.DistinguishedName })
    if ($Preview) {
        return @{
            summary = "Remove $($Members -join ', ') from $($g.Name)"
            changes = @(foreach ($m in $Members) { "Remove-ADGroupMember -Identity '$($g.Name)' -Members '$m'" })
            current = @{ member_count = @($g.member).Count; members = @($g.member | Select-Object -First 20 | ForEach-Object { Get-CnName $_ }) }
        }
    }
    Remove-ADGroupMember -Identity $g -Members $dns -Confirm:$false
    @{ group = $g.Name; removed = @($Members) }
}
