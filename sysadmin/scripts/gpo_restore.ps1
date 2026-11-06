param(
    [Parameter(Mandatory)][string]$Identity,
    [Parameter(Mandatory)][string]$BackupId,
    [switch]$Preview
)
Invoke-Op {
    $gpo = Get-HermesGpo $Identity
    $root = Join-Path $env:ProgramData 'HermesSysadmin\GpoBackups'
    $id = $BackupId.Trim('{}')
    $info = Join-Path (Join-Path $root ('{' + $id + '}')) 'bkupInfo.xml'
    Assert-Hermes (Test-Path $info) "No backup $id under $root."
    [xml]$x = Get-Content -Path $info -Raw
    Assert-Hermes ((Get-XmlText $x.BackupInst.GPOGuid).Trim('{}') -eq $gpo.Id.ToString()) 'That backup belongs to a different GPO.'
    $taken = Iso (Get-XmlText $x.BackupInst.BackupTime)
    if ($Preview) {
        return @{
            summary = "Restore '$($gpo.DisplayName)' from backup taken $taken"
            changes = @("Backup-GPO (current state) -> $root", "Restore-GPO -BackupId $id", 'Links are not changed by a restore.')
            current = @{ modified = (Iso $gpo.ModificationTime); backup_comment = (Get-XmlText $x.BackupInst.Comment) }
        }
    }
    $safety = Backup-GPO -Guid $gpo.Id -Path $root -Comment 'hermes-sysadmin: automatic backup before restore'
    Restore-GPO -BackupId $id -Path $root | Out-Null
    @{ gpo = $gpo.DisplayName; restored_from = $id; backup_time = $taken; safety_backup_id = $safety.Id.ToString() }
}
