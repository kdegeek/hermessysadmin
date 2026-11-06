param([Parameter(Mandatory)][string]$ComputerName)
Invoke-Op {
    $r = Invoke-HermesOne -Computer $ComputerName -Script {
        Import-Module WindowsServerBackup -ErrorAction Stop
        $sets = @(Get-WBBackupSet | Sort-Object BackupTime -Descending | Select-Object -First 100)
        [pscustomobject]@{
            items = @($sets | ForEach-Object {
                [pscustomobject]@{
                    version_id  = "$($_.VersionId)"
                    time        = ([datetime]$_.BackupTime).ToUniversalTime().ToString('o')
                    target      = "$($_.BackupTarget.Label)$($_.BackupTarget.Path)"
                    recoverable = "$($_.RecoverableItems)"
                    volumes     = @($_.Volume | ForEach-Object { "$($_.MountPath)" })
                }
            })
        }
    }
    @{ host = $ComputerName; items = @($r.items | ForEach-Object { @{ version_id = $_.version_id; time = $_.time; target = $_.target; recoverable = $_.recoverable; volumes = @($_.volumes) } }) }
}
