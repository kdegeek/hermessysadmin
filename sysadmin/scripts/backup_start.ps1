param(
    [Parameter(Mandatory)][string]$ComputerName,
    [ValidateSet('system_state', 'policy', 'volumes')][string]$Kind = 'system_state',
    [string]$Target,
    [string[]]$Volumes = @()
)
Invoke-Op {
    Assert-Hermes ($Kind -ne 'volumes' -or $Volumes.Count -gt 0) "kind=volumes needs 'volumes'."
    $r = Invoke-HermesOne -Computer $ComputerName -ArgumentList @($Kind, $Target, $Volumes, $Global:HermesCred) -Script {
        param($K, $T, $V, $C)
        Import-Module WindowsServerBackup -ErrorAction Stop
        $running = Get-WBJob -ErrorAction SilentlyContinue
        if ($running -and "$($running.JobState)" -eq 'Running') { throw 'A backup job is already running on this host.' }
        $scheduled = Get-WBPolicy -ErrorAction SilentlyContinue
        if ($K -eq 'policy') {
            if (-not $scheduled) { throw 'This host has no scheduled backup policy; use kind=system_state or set a policy.' }
            $policy = $scheduled
        } else {
            $policy = New-WBPolicy
            if ($K -eq 'system_state') { Add-WBSystemState -Policy $policy }
            else { foreach ($vol in $V) { Add-WBVolume -Policy $policy -Volume (Get-WBVolume -VolumePath $vol) } }
            if (-not $T) {
                if (-not $scheduled) { throw "Give a 'target' (no scheduled policy to take it from)." }
                # Reuse the scheduled target object: a disk/volume target has no path to rebuild it from.
                $bt = @(Get-WBBackupTarget -Policy $scheduled)[0]
                $T = $(if ($bt.Path) { "$($bt.Path)" } else { "$($bt.Label)" })
            } elseif ($T -like '\\*') { $bt = New-WBBackupTarget -NetworkPath $T -Credential $C }
            else { $bt = New-WBBackupTarget -VolumePath $T }
            Add-WBBackupTarget -Policy $policy -Target $bt | Out-Null
        }
        Start-WBBackup -Policy $policy -Async | Out-Null
        Start-Sleep -Seconds 2
        $j = Get-WBJob -ErrorAction SilentlyContinue
        [pscustomobject]@{ started = $true; target = $T; state = "$($j.JobState)"; operation = "$($j.CurrentOperation)" }
    }
    @{ host = $ComputerName; kind = $Kind; started = $true; target = $r.target; job = @{ state = $r.state; operation = $r.operation } }
}
