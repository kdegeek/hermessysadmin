param([string]$Identity)
Invoke-Op {
    $root = Join-Path $env:ProgramData 'HermesSysadmin\GpoBackups'
    if (-not (Test-Path $root)) { return @{ items = @(); path = $root } }
    $filterId = $null
    if ($Identity) { $filterId = (Get-HermesGpo $Identity).Id.ToString() }
    $items = @(Get-ChildItem -Path $root -Directory | ForEach-Object {
        $info = Join-Path $_.FullName 'bkupInfo.xml'
        if (-not (Test-Path $info)) { return }
        [xml]$x = Get-Content -Path $info -Raw
        $gid = (Get-XmlText $x.BackupInst.GPOGuid).Trim('{}')
        if ($filterId -and $gid -ne $filterId) { return }
        @{
            backup_id = (Get-XmlText $x.BackupInst.ID).Trim('{}')
            gpo_id    = $gid
            gpo       = (Get-XmlText $x.BackupInst.GPODisplayName)
            time      = (Iso (Get-XmlText $x.BackupInst.BackupTime))
            comment   = (Get-XmlText $x.BackupInst.Comment)
        }
    } | Sort-Object { $_.time } -Descending)
    @{ items = $items; path = $root }
}
