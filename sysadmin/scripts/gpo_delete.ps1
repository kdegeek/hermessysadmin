param(
    [Parameter(Mandatory)][string]$Identity,
    [switch]$Preview
)
Invoke-Op {
    $gpo = Get-HermesGpo $Identity
    $guid = '{' + $gpo.Id.ToString().ToUpper() + '}'
    $linked = @(Get-ADObject -LDAPFilter "(gPLink=*$guid*)" | ForEach-Object { $_.DistinguishedName })
    if ($Preview) {
        return @{
            summary = "Delete GPO '$($gpo.DisplayName)'"
            changes = @('Backup-GPO (automatic, before delete)', "Remove-GPO -Guid $($gpo.Id) (removes $($linked.Count) link(s))")
            current = @{ links = $linked; status = "$($gpo.GpoStatus)"; modified = (Iso $gpo.ModificationTime) }
        }
    }
    $root = Join-Path $env:ProgramData 'HermesSysadmin\GpoBackups'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $b = Backup-GPO -Guid $gpo.Id -Path $root -Comment 'hermes-sysadmin: automatic backup before delete'
    Remove-GPO -Guid $gpo.Id -Confirm:$false
    @{ deleted = $gpo.DisplayName; backup_id = $b.Id.ToString(); links_removed = $linked }
}
