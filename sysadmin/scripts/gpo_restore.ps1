param(
    [Parameter(Mandatory)][string]$Identity,
    [Parameter(Mandatory)][string]$BackupId,
    [switch]$Preview
)
Invoke-Op {
    $gpo = Get-HermesGpo $Identity
    $id = $BackupId.Trim('{}')
    Assert-Hermes ($id -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') 'backup_id must be a backup GUID (see gpo_backups).'
    $dc = Get-HermesDc
    # The backup folder is on the DC; read the backup's metadata there.
    $info = Invoke-HermesOnDc -ArgumentList @($id) -Script {
        param($Bid)
        $ErrorActionPreference = 'Stop'
        $root = Join-Path $env:ProgramData 'HermesSysadmin\GpoBackups'
        $file = Join-Path (Join-Path $root ('{' + $Bid + '}')) 'bkupInfo.xml'
        if (-not (Test-Path -LiteralPath $file)) { return [pscustomobject]@{ found = $false; root = $root } }
        [xml]$x = Get-Content -LiteralPath $file -Raw
        $text = { param($Node) if ($null -eq $Node) { '' } elseif ($Node -is [System.Xml.XmlNode]) { $Node.InnerText } else { "$Node" } }
        $taken = & $text $x.BackupInst.BackupTime
        try { $taken = ([datetime]$taken).ToUniversalTime().ToString('o') } catch { }
        [pscustomobject]@{
            found   = $true
            root    = $root
            gpo_id  = (& $text $x.BackupInst.GPOGuid).Trim('{}')
            time    = $taken
            comment = (& $text $x.BackupInst.Comment)
        }
    }
    Assert-Hermes ([bool]$info.found) "No backup $id under $($info.root) on $dc."
    Assert-Hermes ("$($info.gpo_id)" -eq $gpo.Id.ToString()) 'That backup belongs to a different GPO.'
    $taken = "$($info.time)"
    if ($Preview) {
        return @{
            summary = "Restore '$($gpo.DisplayName)' from backup taken $taken"
            changes = @("Backup-GPO (current state) -> $($info.root) on $dc", "Restore-GPO -BackupId $id", 'Links are not changed by a restore.')
            current = @{ modified = (Iso $gpo.ModificationTime); backup_comment = "$($info.comment)" }
        }
    }
    $r = Invoke-HermesOnDc -ArgumentList @($gpo.Id.ToString(), $id, $dc) -Script {
        param($Gid, $Bid, $Dc)
        $ErrorActionPreference = 'Stop'
        Import-Module GroupPolicy
        $root = Join-Path $env:ProgramData 'HermesSysadmin\GpoBackups'
        $safety = Backup-GPO -Guid $Gid -Path $root -Comment 'hermes-sysadmin: automatic backup before restore' -Server $Dc
        Restore-GPO -BackupId $Bid -Path $root -Server $Dc | Out-Null
        [pscustomobject]@{ safety = $safety.Id.ToString() }
    }
    @{ gpo = $gpo.DisplayName; restored_from = $id; backup_time = $taken; safety_backup_id = "$($r.safety)" }
}
