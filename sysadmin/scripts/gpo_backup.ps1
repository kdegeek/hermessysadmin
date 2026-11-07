param(
    [Parameter(Mandatory)][string]$Identity,
    [string]$Comment = 'hermes-sysadmin backup'
)
Invoke-Op {
    $gpo = Get-HermesGpo $Identity
    $dc = Get-HermesDc
    # Backups live on the DC (%ProgramData%\HermesSysadmin\GpoBackups there) whichever transport is in use.
    $b = Invoke-HermesOnDc -ArgumentList @($gpo.Id.ToString(), $Comment, $dc) -Script {
        param($Gid, $Note, $Dc)
        $ErrorActionPreference = 'Stop'
        Import-Module GroupPolicy
        $root = Join-Path $env:ProgramData 'HermesSysadmin\GpoBackups'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $r = Backup-GPO -Guid $Gid -Path $root -Comment $Note -Server $Dc
        [pscustomobject]@{ id = $r.Id.ToString(); time = $r.CreationTime.ToUniversalTime().ToString('o') }
    }
    @{ gpo = $gpo.DisplayName; gpo_id = $gpo.Id.ToString(); backup_id = "$($b.id)"; time = "$($b.time)"; comment = $Comment; dc = $dc }
}
