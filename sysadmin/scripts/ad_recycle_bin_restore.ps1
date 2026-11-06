param(
    [Parameter(Mandatory)][string]$Identity,
    [string]$TargetOu
)
Invoke-Op {
    $o = Get-ADObject -Identity $Identity -IncludeDeletedObjects -Properties 'msDS-LastKnownRDN', lastKnownParent
    $splat = @{ Identity = $o; PassThru = $true }
    if ($TargetOu) { $splat.TargetPath = $TargetOu }
    $r = Restore-ADObject @splat
    @{ restored = "$($o.'msDS-LastKnownRDN')"; dn = $r.DistinguishedName; to = $(if ($TargetOu) { $TargetOu } else { $o.lastKnownParent }) }
}
