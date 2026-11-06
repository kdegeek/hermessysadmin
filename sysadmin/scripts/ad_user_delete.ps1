param(
    [Parameter(Mandatory)][string]$Identity,
    [switch]$Preview
)
Invoke-Op {
    $u = Get-ADUser -Identity $Identity -Properties MemberOf, Enabled, LastLogonDate
    Assert-HermesNotProtected $u
    $recycle = @(Get-ADOptionalFeature -Filter "Name -eq 'Recycle Bin Feature'" | Where-Object { $_.EnabledScopes.Count -gt 0 }).Count -gt 0
    if ($Preview) {
        $note = if ($recycle) { 'AD Recycle Bin is enabled: the account can be restored with ad_recycle_bin_restore.' } else { 'AD Recycle Bin is NOT enabled: this cannot be undone without an authoritative restore.' }
        return @{
            summary = "Delete user $($u.SamAccountName) ($($u.DistinguishedName))"
            changes = @("Remove-ADObject -Identity '$($u.DistinguishedName)' -Recursive", $note)
            current = @{ enabled = [bool]$u.Enabled; last_logon = (Iso $u.LastLogonDate); groups = @($u.MemberOf | ForEach-Object { Get-CnName $_ }) }
        }
    }
    Remove-ADObject -Identity $u.DistinguishedName -Recursive -Confirm:$false
    @{ deleted = $u.DistinguishedName; sam = $u.SamAccountName; recycle_bin = $recycle }
}
