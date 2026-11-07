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
    $dc = Get-HermesDc
    # The safety backup goes to the backup folder on the DC, like gpo_backup.
    $b = Invoke-HermesOnDc -ArgumentList @($gpo.Id.ToString(), $dc) -Script {
        param($Gid, $Dc)
        $ErrorActionPreference = 'Stop'
        Import-Module GroupPolicy
        $root = Join-Path $env:ProgramData 'HermesSysadmin\GpoBackups'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $r = Backup-GPO -Guid $Gid -Path $root -Comment 'hermes-sysadmin: automatic backup before delete' -Server $Dc
        [pscustomobject]@{ id = $r.Id.ToString() }
    }
    Assert-Hermes ([bool]"$($b.id)") 'The automatic backup before delete did not complete; nothing was deleted.'
    Remove-GPO -Guid $gpo.Id -Confirm:$false
    @{ deleted = $gpo.DisplayName; backup_id = "$($b.id)"; links_removed = $linked }
}
