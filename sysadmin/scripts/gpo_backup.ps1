param(
    [Parameter(Mandatory)][string]$Identity,
    [string]$Comment = 'hermes-sysadmin backup'
)
Invoke-Op {
    $gpo = Get-HermesGpo $Identity
    $root = Join-Path $env:ProgramData 'HermesSysadmin\GpoBackups'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $b = Backup-GPO -Guid $gpo.Id -Path $root -Comment $Comment
    @{ gpo = $gpo.DisplayName; gpo_id = $gpo.Id.ToString(); backup_id = $b.Id.ToString(); time = (Iso $b.Timestamp); comment = $Comment }
}
