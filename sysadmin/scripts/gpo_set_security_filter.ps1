param(
    [Parameter(Mandatory)][string]$Identity,
    [string[]]$Add = @(),
    [string[]]$Remove = @()
)
Invoke-Op {
    Assert-Hermes (($Add.Count + $Remove.Count) -gt 0) 'Give principals to add and/or remove.'
    $gpo = Get-HermesGpo $Identity
    $typeOf = {
        param($n)
        $o = Get-ADObject -LDAPFilter "(sAMAccountName=$(ConvertTo-LdapValue $n))" | Select-Object -First 1
        if (-not $o) { return 'Group' }
        switch ($o.ObjectClass) { 'computer' { 'Computer' } 'user' { 'User' } default { 'Group' } }
    }
    foreach ($n in $Add) {
        Set-GPPermission -Guid $gpo.Id -TargetName $n -TargetType (& $typeOf $n) -PermissionLevel GpoApply | Out-Null
    }
    foreach ($n in $Remove) {
        if ($n -eq 'Authenticated Users') {
            Set-GPPermission -Guid $gpo.Id -TargetName $n -TargetType Group -PermissionLevel GpoRead -Replace | Out-Null
        } else {
            Set-GPPermission -Guid $gpo.Id -TargetName $n -TargetType (& $typeOf $n) -PermissionLevel None -Replace | Out-Null
        }
    }
    $apply = @(Get-GPPermission -Guid $gpo.Id -All | Where-Object { "$($_.Permission)" -eq 'GpoApply' } | ForEach-Object { "$($_.Trustee.Name)" })
    @{ gpo = $gpo.DisplayName; added = @($Add); removed = @($Remove); security_filtering = $apply }
}
