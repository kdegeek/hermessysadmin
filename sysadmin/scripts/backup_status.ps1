param(
    [string[]]$Hosts = @(),
    [string]$Ou,
    [string]$ServerSearchBase
)
Invoke-Op {
    $targets = @(Get-HermesTargets -Computers $Hosts -Ou $Ou -SearchBase $ServerSearchBase)
    Assert-Hermes ($targets.Count -gt 0) 'No target computers found.'
    $remote = Get-HermesFanout -Computers $targets -Script {
        $iso = { param($d) if ($d -and ([datetime]$d) -gt [datetime]'1990-01-01') { ([datetime]$d).ToUniversalTime().ToString('o') } else { $null } }
        $feature = Get-WindowsFeature -Name Windows-Server-Backup -ErrorAction SilentlyContinue
        if (-not $feature -or -not $feature.Installed) {
            return [pscustomobject]@{ installed = $false; policy = $false; versions = 0; job = $null }
        }
        Import-Module WindowsServerBackup -ErrorAction Stop
        $s = Get-WBSummary
        $p = Get-WBPolicy -ErrorAction SilentlyContinue
        $target = $null
        if ($p) { $target = (@(Get-WBBackupTarget -Policy $p) | ForEach-Object { if ($_.Path) { "$($_.Path)" } else { "$($_.Label)" } }) -join ', ' }
        $ss = @(Get-WBBackupSet -ErrorAction SilentlyContinue | Where-Object { "$($_.RecoverableItems)" -match 'SystemState' } | Sort-Object BackupTime -Descending | Select-Object -First 1)
        $j = Get-WBJob -ErrorAction SilentlyContinue
        $job = $null
        if ($j -and "$($j.JobState)" -eq 'Running') {
            $pct = $null
            if ("$($j.CurrentOperation)" -match '(\d{1,3})\s*%') { $pct = [int]$Matches[1] }
            $job = [pscustomobject]@{ running = $true; type = "$($j.JobType)"; operation = "$($j.CurrentOperation)"; percent = $pct; started = (& $iso $j.StartTime) }
        }
        [pscustomobject]@{
            installed         = $true
            policy            = [bool]$p
            last_success      = (& $iso $s.LastSuccessfulBackupTime)
            last_backup       = (& $iso $s.LastBackupTime)
            last_result_hr    = [int]$s.LastBackupResultHR
            message           = "$($s.DetailedMessage)"
            next_run          = (& $iso $s.NextBackupTime)
            versions          = [int]$s.NumberOfVersions
            target            = $target
            last_system_state = $(if ($ss.Count -gt 0) { & $iso $ss[0].BackupTime } else { $null })
            job               = $job
        }
    }
    @{ results = $remote.results; errors = $remote.errors; targets = $targets.Count }
}
