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
    # Only trustees whose permission is exactly GpoApply are in the filter. Never touch a
    # trustee with edit/delegation rights: -Replace would strip those rights too.
    $removed = @()
    $skipped = @()
    foreach ($n in $Remove) {
        $type = $(if ($n -eq 'Authenticated Users') { 'Group' } else { & $typeOf $n })
        $current = $null
        try { $current = Get-GPPermission -Guid $gpo.Id -TargetName $n -TargetType $type -ErrorAction Stop } catch { $current = $null }
        if (-not $current -or "$($current.Permission)" -ne 'GpoApply') {
            $skipped += @{ principal = $n; reason = $(if ($current) { "has $($current.Permission), not GpoApply; left unchanged" } else { 'not in the security filter' }) }
            continue
        }
        $level = $(if ($n -eq 'Authenticated Users') { 'GpoRead' } else { 'None' })
        Set-GPPermission -Guid $gpo.Id -TargetName $n -TargetType $type -PermissionLevel $level -Replace | Out-Null
        $removed += $n
    }
    $apply = @(Get-GPPermission -Guid $gpo.Id -All | Where-Object { "$($_.Permission)" -eq 'GpoApply' } | ForEach-Object { "$($_.Trustee.Name)" })
    @{ gpo = $gpo.DisplayName; added = @($Add); removed = $removed; skipped = $skipped; security_filtering = $apply }
}
