param(
    [Parameter(Mandatory)][string]$Group,
    [Parameter(Mandatory)][string[]]$Members,
    [switch]$Preview
)
Invoke-Op {
    $g = Get-ADGroup -Identity $Group -Properties member
    foreach ($m in $Members) {
        $v = ConvertTo-LdapValue $m
        $found = @(Get-ADObject -LDAPFilter "(|(sAMAccountName=$v)(distinguishedName=$v)(userPrincipalName=$v)(cn=$v))" -Properties objectSid, primaryGroupID, isCriticalSystemObject)
        if ($found.Count -eq 0) { throw "Cannot find an object with identity '$m'." }
        foreach ($f in $found) { Assert-HermesNotProtected $f }
    }
    if ($Preview) {
        return @{
            summary = "Remove $($Members -join ', ') from $($g.Name)"
            changes = @(foreach ($m in $Members) { "Remove-ADGroupMember -Identity '$($g.Name)' -Members '$m'" })
            current = @{ member_count = @($g.member).Count; members = @($g.member | Select-Object -First 20 | ForEach-Object { Get-CnName $_ }) }
        }
    }
    Remove-ADGroupMember -Identity $g -Members $Members -Confirm:$false
    @{ group = $g.Name; removed = @($Members) }
}
